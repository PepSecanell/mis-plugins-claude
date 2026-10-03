import Foundation
import SwiftData
import Observation

/// Runs the agents: streaming replies, private agent-to-agent consults,
/// group-chat hand-offs and the shared "About me" memory.
@MainActor
@Observable
final class AgentEngine {
    /// Conversations that are currently generating.
    private(set) var busyConversations: Set<UUID> = []
    /// Messages that are still streaming in.
    private(set) var streamingMessages: Set<UUID> = []
    /// Short live status per message, e.g. "Searching the web…".
    private(set) var status: [UUID: String] = [:]

    let context: ModelContext
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]

    /// How deep agents may consult each other (main → specialist → specialist).
    private let maxConsultDepth = 2
    private let maxToolRounds = 16

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Public API

    func isBusy(_ conversation: Conversation) -> Bool {
        busyConversations.contains(conversation.id)
    }

    func send(_ text: String, in conversation: Conversation) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBusy(conversation) else { return }
        append(ChatMessage(kind: .user, text: trimmed), to: conversation)
        save()

        let id = conversation.id
        busyConversations.insert(id)
        tasks[id] = Task { [weak self] in
            await self?.respond(to: trimmed, in: conversation)
            self?.busyConversations.remove(id)
            self?.tasks[id] = nil
            self?.save()
        }
    }

    /// Throws away everything after the last user message and asks again.
    func regenerate(in conversation: Conversation) {
        guard !isBusy(conversation),
              let lastUser = conversation.sortedMessages.last(where: { $0.messageKind == .user }) else { return }
        for message in conversation.sortedMessages where message.createdAt > lastUser.createdAt {
            context.delete(message)
        }
        save()
        let id = conversation.id
        let text = lastUser.text
        busyConversations.insert(id)
        tasks[id] = Task { [weak self] in
            await self?.respond(to: text, in: conversation)
            self?.busyConversations.remove(id)
            self?.tasks[id] = nil
            self?.save()
        }
    }

    /// Deletes one message, plus the private consult cards that belong to it.
    func delete(_ message: ChatMessage, in conversation: Conversation) {
        for card in conversation.messages ?? [] where card.parentID == message.id {
            context.delete(card)
        }
        context.delete(message)
        save()
    }

    func stop(_ conversation: Conversation) {
        tasks[conversation.id]?.cancel()
    }

    func stopAll() {
        tasks.values.forEach { $0.cancel() }
    }

    /// False once a model was deleted (e.g. the user deleted the chat mid-reply); writing to it would crash.
    private func alive(_ model: any PersistentModel) -> Bool {
        !model.isDeleted && model.modelContext != nil
    }

    /// Drafts a tagline and instructions for a new agent from a short description.
    /// Runs on the provider and model chosen in the editor, or on the first provider with a key.
    func draftAgent(name: String, description: String, provider: Provider,
                    model: String) async throws -> (tagline: String, instructions: String) {
        var provider = provider
        var model = model
        if Keychain.key(for: provider) == nil, let fallback = Provider.configured.first {
            provider = fallback
            model = ProviderSettings.defaultModel(for: fallback)
        }
        guard Keychain.key(for: provider) != nil else {
            throw ClaudeError(message: "Add an API key in Settings first.")
        }
        if model.isEmpty { model = ProviderSettings.defaultModel(for: provider) }
        let prompt = """
        Write the configuration for a personal AI agent called "\(name)".
        What the user wants it to do: \(description)

        Reply in exactly this format and nothing else:
        TAGLINE: <one sentence, max 15 words, describing its specialty>
        INSTRUCTIONS:
        <the agent's system prompt in second person ("You are…"): its expertise, how it should think, \
        what to ask the user, how to format answers for a phone screen, and any safety limits. 150-350 words.>
        """
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
        ]
        if provider == .anthropic {
            body["max_tokens"] = 4000
            if ModelCatalog.supportsAdaptiveThinking(model) {
                body["thinking"] = ["type": "adaptive"]
                body["output_config"] = ["effort": "low"]
            }
        }
        let response = try await ClientPool().stream(provider: provider, body: body, betas: []) { _ in }
        let text = ClaudeClient.text(of: response.content)
        let parts = text.components(separatedBy: "INSTRUCTIONS:")
        let tagline = parts.first?
            .replacingOccurrences(of: "TAGLINE:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let instructions = parts.count > 1
            ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            : text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (tagline, instructions)
    }

    // MARK: - Turn orchestration

    private func respond(to text: String, in conversation: Conversation) async {
        guard !Provider.configured.isEmpty else {
            append(ChatMessage(kind: .notice, text: "Add an API key in Settings (⚙️) to start chatting. Any supported AI provider works."), to: conversation)
            return
        }
        let clients = ClientPool()
        let members = agents(in: conversation)
        guard !members.isEmpty else {
            append(ChatMessage(kind: .notice, text: "This chat has no agents. Add one from the chat's info screen."), to: conversation)
            return
        }

        // Who replies: @mentioned agents, otherwise the lead (main agent if present) —
        // the lead can then hand off to whoever is better suited, like Grok Bot group chats.
        var queue: [Agent]
        if conversation.isGroup {
            queue = Mentions.agents(mentionedIn: text, among: members)
            if queue.isEmpty {
                queue = [members.first(where: \.isMain) ?? members[0]]
            }
        } else {
            queue = [members[0]]
        }

        var handoffBudget = 4
        var index = 0
        while index < queue.count, !Task.isCancelled {
            let agent = queue[index]
            index += 1
            let handoffs = await runVisibleTurn(agent: agent, in: conversation, clients: clients)
            for next in handoffs where handoffBudget > 0 && !queue[index...].contains(where: { $0.id == next.id }) {
                queue.append(next)
                handoffBudget -= 1
            }
        }
    }

    /// One agent writes one visible reply in the conversation. Returns agents it handed off to.
    private func runVisibleTurn(agent: Agent, in conversation: Conversation, clients: ClientPool) async -> [Agent] {
        let reply = ChatMessage(kind: .agent, agentID: agent.id)
        let history = buildHistory(for: agent, in: conversation)
        append(reply, to: conversation)
        streamingMessages.insert(reply.id)
        defer {
            streamingMessages.remove(reply.id)
            status[reply.id] = nil
            if alive(conversation) { conversation.updatedAt = Date() }
            save()
        }

        let system = systemPrompt(for: agent, conversation: conversation, consultedBy: nil)
        do {
            let result = try await runLoop(agent: agent, system: system, messages: history, depth: 0,
                                           sink: reply, root: reply, conversation: conversation, clients: clients)
            return result.handoffs
        } catch {
            guard alive(reply) else { return [] }
            if Self.isCancellation(error) {
                if reply.text.isEmpty { reply.text = "_Stopped._" }
            } else {
                reply.text += (reply.text.isEmpty ? "" : "\n\n") + "⚠️ " + error.localizedDescription
            }
            return []
        }
    }

    private struct LoopResult {
        var handoffs: [Agent] = []
    }

    /// The agentic loop: stream a response, run any tools it asked for, feed results back, repeat.
    /// Everything the API returns inside the loop is echoed back unchanged (thinking, tool calls,
    /// search results), so the loop stays append-only.
    private func runLoop(agent: Agent, system: String, messages initial: [[String: Any]], depth: Int,
                         sink: ChatMessage, root: ChatMessage, conversation: Conversation,
                         clients: ClientPool) async throws -> LoopResult {
        var messages = initial
        var result = LoopResult()
        let tools = toolDefinitions(for: agent, conversation: conversation, depth: depth)
        var sources = sink.sources

        for _ in 0..<maxToolRounds {
            try Task.checkCancellation()
            guard alive(agent), alive(sink), alive(conversation) else { throw CancellationError() }
            let provider = agent.providerKind
            var body: [String: Any] = [
                "model": agent.model,
                "system": [["type": "text", "text": system]],
                "messages": messages,
            ]
            if !tools.isEmpty { body["tools"] = tools }
            var betas: [String] = []
            if provider == .anthropic {
                body["max_tokens"] = 32000
                body["cache_control"] = ["type": "ephemeral"]
                if ModelCatalog.supportsAdaptiveThinking(agent.model) {
                    body["thinking"] = ["type": "adaptive", "display": "summarized"]
                    body["output_config"] = ["effort": agent.effort]
                }
                if ModelCatalog.supportsFallbacks(agent.model) {
                    // If a safety classifier declines, the API retries on a fallback model server-side.
                    body["fallbacks"] = "default"
                    betas.append("server-side-fallback-2026-07-01")
                }
            }

            let sinkID = sink.id
            status[sinkID] = "Thinking…"
            let response = try await clients.stream(provider: provider, body: body, betas: betas) { [weak self] event in
                guard let self, self.alive(sink) else { return }
                switch event {
                case .text(let chunk):
                    sink.text += chunk
                    self.status[sinkID] = ""
                case .thinking(let chunk):
                    sink.thinking += chunk
                case .blockStarted(let type, let name):
                    switch type {
                    case "text":
                        if !sink.text.isEmpty && !sink.text.hasSuffix("\n") { sink.text += "\n\n" }
                    case "server_tool_use":
                        self.status[sinkID] = "Searching the web…"
                    case "tool_use":
                        switch name {
                        case "ask_agent": self.status[sinkID] = "Consulting teammates…"
                        case "remember", "forget": self.status[sinkID] = "Updating memory…"
                        case "hand_off": self.status[sinkID] = "Handing off…"
                        case "create_agent", "update_agent", "delete_agent", "create_group_chat", "update_group_chat":
                            self.status[sinkID] = "Setting up your team…"
                        default: self.status[sinkID] = "Working…"
                        }
                    case "thinking", "redacted_thinking":
                        self.status[sinkID] = "Thinking…"
                    default:
                        break
                    }
                }
            }

            guard alive(sink), alive(conversation) else { throw CancellationError() }
            sources.append(contentsOf: Self.webSources(in: response.content))
            if !sources.isEmpty { sink.sources = Self.unique(sources) }
            messages.append(["role": "assistant", "content": response.content])

            switch response.stopReason {
            case "tool_use":
                let toolUses = response.content.filter { $0["type"] as? String == "tool_use" }
                let (results, handoffs) = await runTools(toolUses, agent: agent, invalidIDs: response.invalidToolUseIDs,
                                                         depth: depth, root: root, conversation: conversation, clients: clients)
                result.handoffs.append(contentsOf: handoffs)
                messages.append(["role": "user", "content": results])
            case "pause_turn":
                continue // a long server-side web search paused; sending the turn back resumes it
            case "refusal":
                sink.text += (sink.text.isEmpty ? "" : "\n\n") + "_I can't help with that request._"
                return result
            case "max_tokens":
                sink.text += "\n\n_(Reply cut off: it reached the length limit.)_"
                return result
            default:
                return result
            }
        }
        sink.text += "\n\n_(Stopped after too many steps.)_"
        return result
    }

    // MARK: - Tools

    private func toolDefinitions(for agent: Agent, conversation: Conversation, depth: Int) -> [[String: Any]] {
        var tools: [[String: Any]] = []
        let others = allAgents().filter { $0.id != agent.id }
        if agent.canConsult && depth < maxConsultDepth && !others.isEmpty {
            tools.append([
                "name": "ask_agent",
                "description": """
                Privately consult one teammate agent and get their answer back. Call it several times in \
                the same turn to consult several teammates in parallel. The teammate cannot see this chat, \
                so include all the context they need (the user's goal, constraints, relevant facts).
                """,
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "agent_name": ["type": "string", "description": "Exact name of the teammate to consult."],
                        "message": ["type": "string", "description": "Your question plus the context they need."],
                    ],
                    "required": ["agent_name", "message"],
                ],
                "eager_input_streaming": true,
            ])
        }
        if conversation.isGroup && depth == 0 && agents(in: conversation).count > 1 {
            tools.append([
                "name": "hand_off",
                "description": """
                Hand the conversation to another member of this group chat so they reply next, visibly, \
                in the chat. Use it when their specialty fits the user's request better than yours. \
                After calling it, finish with at most one short sentence.
                """,
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "agent_name": ["type": "string", "description": "Exact name of a group member."],
                        "note": ["type": "string", "description": "What you need them to cover."],
                    ],
                    "required": ["agent_name", "note"],
                ],
                "eager_input_streaming": true,
            ])
        }
        tools.append([
            "name": "remember",
            "description": """
            Save a lasting fact about the user to the shared memory every agent can read \
            (goals, body stats, preferences, schedule, results, channel niche…). One short fact per call.
            """,
            "input_schema": [
                "type": "object",
                "properties": ["fact": ["type": "string", "description": "The fact, in one short sentence."]],
                "required": ["fact"],
            ],
            "eager_input_streaming": true,
        ])
        tools.append([
            "name": "forget",
            "description": "Delete an outdated or wrong fact from shared memory, by its id.",
            "input_schema": [
                "type": "object",
                "properties": ["memory_id": ["type": "string", "description": "The id shown in brackets, e.g. a1b2c3."]],
                "required": ["memory_id"],
            ],
            "eager_input_streaming": true,
        ])
        if agent.isMain && depth == 0 {
            tools.append(contentsOf: TeamTools.definitions)
        }
        if agent.webSearch && agent.providerKind.supportsWebSearch {
            tools.append(["type": ModelCatalog.webSearchToolType(agent.model), "name": "web_search", "max_uses": 6])
        }
        return tools
    }

    /// Runs the client-side tool calls of one assistant turn. Consults run in parallel.
    private func runTools(_ toolUses: [[String: Any]], agent: Agent, invalidIDs: Set<String>, depth: Int,
                          root: ChatMessage, conversation: Conversation,
                          clients: ClientPool) async -> ([[String: Any]], [Agent]) {
        var outputs = [(text: String, isError: Bool)](repeating: ("", false), count: toolUses.count)
        var handoffs: [Agent] = []
        var consults: [(index: Int, target: String, question: String)] = []

        for (i, use) in toolUses.enumerated() {
            let id = use["id"] as? String ?? ""
            let name = use["name"] as? String ?? ""
            let input = use["input"] as? [String: Any] ?? [:]
            func field(_ key: String) -> String? {
                let value = (input[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return (value?.isEmpty ?? true) ? nil : value
            }
            if invalidIDs.contains(id) {
                outputs[i] = ("The tool input was not valid JSON. Try the call again.", true)
                continue
            }
            switch name {
            case "ask_agent":
                if let target = field("agent_name"), let question = field("message") {
                    consults.append((i, target, question))
                } else {
                    outputs[i] = ("Both agent_name and message are required.", true)
                }
            case "hand_off":
                guard let targetName = field("agent_name"), let note = field("note") else {
                    outputs[i] = ("Both agent_name and note are required.", true)
                    continue
                }
                let members = agents(in: conversation)
                if let target = Self.match(targetName, in: members), target.id != agent.id {
                    handoffs.append(target)
                    let marker = ChatMessage(kind: .handoff, agentID: target.id, fromAgentID: agent.id, question: note)
                    append(marker, to: conversation)
                    outputs[i] = ("\(target.name) will reply next in the chat.", false)
                } else {
                    let names = members.filter { $0.id != agent.id }.map(\.name).joined(separator: ", ")
                    outputs[i] = ("No group member called \"\(targetName)\". Members: \(names).", true)
                }
            case "remember":
                if let fact = field("fact") {
                    let item = MemoryItem(text: fact, sourceAgentName: agent.name)
                    context.insert(item)
                    outputs[i] = ("Saved to memory as [\(item.shortID)].", false)
                } else {
                    outputs[i] = ("fact is required.", true)
                }
            case "forget":
                let wanted = field("memory_id")?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) ?? ""
                if let item = allMemories().first(where: { $0.shortID == wanted }) {
                    context.delete(item)
                    outputs[i] = ("Deleted.", false)
                } else {
                    outputs[i] = ("No memory with id \(wanted).", true)
                }
            default:
                outputs[i] = runTeamTool(name, input: input, agent: agent, conversation: conversation)
                    ?? ("Unknown tool \(name).", true)
            }
        }

        if !consults.isEmpty {
            let answers = await withTaskGroup(of: (Int, String, Bool).self) { group in
                for consult in consults {
                    group.addTask { @MainActor in
                        let (text, isError) = await self.consult(asker: agent, targetName: consult.target,
                                                                 question: consult.question, depth: depth,
                                                                 root: root, conversation: conversation, clients: clients)
                        return (consult.index, text, isError)
                    }
                }
                var collected: [(Int, String, Bool)] = []
                for await answer in group { collected.append(answer) }
                return collected
            }
            for (index, text, isError) in answers { outputs[index] = (text, isError) }
        }

        let results: [[String: Any]] = toolUses.enumerated().map { i, use in
            var block: [String: Any] = [
                "type": "tool_result",
                "tool_use_id": use["id"] as? String ?? "",
                "content": outputs[i].text.isEmpty ? "(empty)" : outputs[i].text,
            ]
            if outputs[i].isError { block["is_error"] = true }
            return block
        }
        return (results, handoffs)
    }

    /// A private agent-to-agent conversation. Shown in the UI as a collapsible card under the reply.
    private func consult(asker: Agent, targetName: String, question: String, depth: Int, root: ChatMessage,
                         conversation: Conversation, clients: ClientPool) async -> (String, Bool) {
        let candidates = allAgents().filter { $0.id != asker.id }
        guard let target = Self.match(targetName, in: candidates) else {
            let names = candidates.map(\.name).joined(separator: ", ")
            return ("No teammate called \"\(targetName)\". Teammates: \(names).", true)
        }
        let card = ChatMessage(kind: .consult, agentID: target.id, fromAgentID: asker.id, question: question)
        card.parentIDRaw = root.id.uuidString
        append(card, to: conversation)
        streamingMessages.insert(card.id)
        defer {
            streamingMessages.remove(card.id)
            status[card.id] = nil
        }

        let system = systemPrompt(for: target, conversation: nil, consultedBy: asker)
        let messages: [[String: Any]] = [["role": "user", "content": "\(asker.name) asks you:\n\n\(question)"]]
        do {
            _ = try await runLoop(agent: target, system: system, messages: messages, depth: depth + 1,
                                  sink: card, root: root, conversation: conversation, clients: clients)
            let answer = card.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return (answer.isEmpty ? "(\(target.name) had nothing to add.)" : "\(target.name) says:\n\n\(answer)", false)
        } catch {
            if Self.isCancellation(error) || !alive(card) { return ("Cancelled.", true) }
            card.text += (card.text.isEmpty ? "" : "\n\n") + "⚠️ " + error.localizedDescription
            return ("\(target.name) couldn't answer: \(error.localizedDescription)", true)
        }
    }

    // MARK: - Prompt building

    private func systemPrompt(for agent: Agent, conversation: Conversation?, consultedBy asker: Agent?) -> String {
        var parts: [String] = []
        let instructions = agent.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        parts.append(instructions.isEmpty ? "You are \(agent.name), a helpful specialist agent." : instructions)

        var howYouWork = "# How you work\nYou are \"\(agent.name)\", one of the user's personal AI agents in the Agents app."
        if agent.isMain {
            howYouWork += " You are the MAIN agent, the user's chief of staff: coordinate the team, consult specialists (several at once when useful) and merge their input into one clear answer or plan."
            howYouWork += """
            \n\nYou also build and manage the user's team inside the app. With list_agents, create_agent, update_agent, \
            delete_agent, create_group_chat and update_group_chat you can do everything the app's screens can: \
            add specialists, rewrite their instructions, change their emoji, color, label, AI provider and model, \
            and set up group chats. When the user wants help with an area of their life or work, get to know them \
            first with a few short questions, then propose a small team (usually 2-5 agents) and create it once they \
            agree. Write each agent's instructions specifically for this user. Ask before deleting anything. \
            You can't see or change API keys; those live in Settings.
            """
        }
        howYouWork += "\nToday is \(Date.now.formatted(date: .complete, time: .omitted))."
        parts.append(howYouWork)

        let teammates = allAgents().filter { $0.id != agent.id }
        if !teammates.isEmpty {
            var team = "## Your teammates\n"
            team += teammates.map { "- \($0.emoji) \($0.name) [\($0.team)]: \($0.tagline)" }.joined(separator: "\n")
            if agent.canConsult {
                team += "\n\nUse ask_agent when a teammate's specialty would clearly improve your answer; skip it for things you can answer well yourself. When you use their input, say briefly who contributed what."
            }
            parts.append(team)
        }

        let memories = allMemories()
        var memory = "## What you know about the user (shared memory)\n"
        memory += memories.isEmpty
            ? "Nothing yet."
            : memories.map { "- [\($0.shortID)] \($0.text)" }.joined(separator: "\n")
        memory += "\n\nWhen the user shares a lasting fact about themselves, save it with remember. Remove outdated facts with forget. Don't save things already listed."
        parts.append(memory)

        if let asker {
            parts.append("""
            ## Right now
            \(asker.name), a teammate, is consulting you privately; the user sees your answer only as a collapsed \
            note and \(asker.name) will relay it. Answer \(asker.name)'s question directly with your specialist view, \
            in under 250 words. No greetings.
            """)
        } else if let conversation, conversation.isGroup {
            let names = agents(in: conversation).map(\.name).joined(separator: ", ")
            parts.append("""
            ## This chat
            This is a group chat between the user and these agents: \(names). Messages from others are prefixed \
            with [Name]; the user's are prefixed with [User]. You are replying as \(agent.name): write only your \
            own reply, never lines for other agents. If another member fits the request better, use hand_off. \
            Don't repeat what other agents already said; build on it or disagree with reasons.
            """)
        }

        parts.append("""
        ## Style
        The user reads you on a phone. Be warm, direct and practical: short paragraphs, bullet lists, **bold** \
        for key points. No long preambles. Ask a quick question when you need information to give a good answer.
        """)
        return parts.joined(separator: "\n\n")
    }

    /// Converts the visible chat into Messages API turns for one agent. Only final text is replayed,
    /// so the history is identical on every request and stays cacheable.
    private func buildHistory(for agent: Agent, in conversation: Conversation) -> [[String: Any]] {
        let byID = Dictionary(allAgents().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var turns: [(role: String, text: String)] = []
        for message in conversation.sortedMessages.suffix(80) {
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch message.messageKind {
            case .user:
                turns.append(("user", conversation.isGroup ? "[User]: \(text)" : text))
            case .agent:
                guard !text.isEmpty else { continue }
                if message.agentID == agent.id {
                    turns.append(("assistant", text))
                } else {
                    let name = message.agentID.flatMap { byID[$0]?.name } ?? "Agent"
                    turns.append(("user", "[\(name)]: \(text)"))
                }
            case .handoff:
                let from = message.fromAgentID.flatMap { byID[$0]?.name } ?? "Agent"
                let to = message.agentID.flatMap { byID[$0]?.name } ?? "Agent"
                turns.append(("user", "[\(from) handed off to \(to)]: \(message.question)"))
            case .consult, .notice:
                continue
            }
        }

        var merged: [(role: String, text: String)] = []
        for turn in turns where !turn.text.isEmpty {
            if let last = merged.last, last.role == turn.role {
                merged[merged.count - 1].text += "\n\n" + turn.text
            } else {
                merged.append(turn)
            }
        }
        while merged.first?.role == "assistant" { merged.removeFirst() }
        if merged.last?.role != "user" { merged.append(("user", "(Continue.)")) }
        return merged.map { ["role": $0.role, "content": $0.text] }
    }

    // MARK: - Data helpers

    func allAgents() -> [Agent] {
        let descriptor = FetchDescriptor<Agent>(sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)])
        return (try? context.fetch(descriptor)) ?? []
    }

    private func allMemories() -> [MemoryItem] {
        let descriptor = FetchDescriptor<MemoryItem>(sortBy: [SortDescriptor(\.createdAt)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func agents(in conversation: Conversation) -> [Agent] {
        let byID = Dictionary(allAgents().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return conversation.memberIDs.compactMap { byID[$0] }
    }

    func append(_ message: ChatMessage, to conversation: Conversation) {
        guard alive(conversation) else { return }
        context.insert(message)
        if conversation.messages == nil { conversation.messages = [] }
        conversation.messages?.append(message)
        conversation.updatedAt = Date()
    }

    func save() {
        try? context.save()
    }

    static func match(_ name: String, in agents: [Agent]) -> Agent? {
        let wanted = Mentions.normalize(name)
        return agents.first { Mentions.normalize($0.name) == wanted }
            ?? agents.first { Mentions.normalize($0.name).contains(wanted) || wanted.contains(Mentions.normalize($0.name)) }
    }

    private static func webSources(in content: [[String: Any]]) -> [ChatMessage.Source] {
        content.filter { $0["type"] as? String == "web_search_tool_result" }
            .flatMap { ($0["content"] as? [[String: Any]]) ?? [] }
            .compactMap { item in
                guard let url = item["url"] as? String else { return nil }
                return ChatMessage.Source(title: item["title"] as? String ?? url, url: url)
            }
    }

    private static func unique(_ sources: [ChatMessage.Source]) -> [ChatMessage.Source] {
        var seen: Set<String> = []
        return sources.filter { seen.insert($0.url).inserted }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }
}

enum Mentions {
    /// Lower-cased letters and digits only, so "@Don't Die" and "@dontdie" match.
    static func normalize(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Agents @mentioned in the text, in the order they appear. "@everyone" / "@all" selects all.
    static func agents(mentionedIn text: String, among agents: [Agent]) -> [Agent] {
        let lowered = text.lowercased()
        if lowered.contains("@everyone") || lowered.contains("@all") { return agents }
        // Normalise while keeping "@" so mentions can be located.
        let flattened = String(lowered.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) || $0 == "@" }
            .map(Character.init))
        var found: [(position: String.Index, agent: Agent)] = []
        for agent in agents {
            if let range = flattened.range(of: "@" + normalize(agent.name)) {
                found.append((range.lowerBound, agent))
            }
        }
        return found.sorted { $0.position < $1.position }.map(\.agent)
    }
}
