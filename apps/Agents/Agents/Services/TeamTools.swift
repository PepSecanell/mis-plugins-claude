import Foundation
import SwiftData

/// Tools that let the main agent build and run the user's team from the chat:
/// list, create, edit and delete agents, and set up group chats.
enum TeamTools {
    static let names: Set<String> = ["list_agents", "create_agent", "update_agent", "delete_agent",
                                     "create_group_chat", "update_group_chat"]

    private static let agentFields: [String: Any] = [
        "emoji": ["type": "string", "description": "One emoji for its avatar."],
        "color": ["type": "string", "description": "Avatar color as hex, e.g. #46A758."],
        "label": ["type": "string", "description": "Short team or topic label shown under the name, e.g. Health."],
        "tagline": ["type": "string", "description": "One line on what it's great at. Teammates see this."],
        "instructions": ["type": "string", "description": "Its full system prompt in second person (\"You are…\"): expertise, how it thinks, what it asks the user, answer format for a phone, safety limits. 150-400 words."],
        "provider": ["type": "string", "enum": Provider.allCases.map(\.rawValue), "description": "AI provider. Only providers listed as having a key work."],
        "model": ["type": "string", "description": "Model id from that provider's list in list_agents. Omit to use the provider's default."],
        "effort": ["type": "string", "enum": ModelCatalog.efforts, "description": "Thinking effort (Anthropic models only)."],
        "web_search": ["type": "boolean", "description": "Let it search the web (Anthropic models only)."],
        "can_consult": ["type": "boolean", "description": "Let it consult teammates."],
    ]

    static var definitions: [[String: Any]] {
        var createProps = agentFields
        createProps["name"] = ["type": "string", "description": "The agent's name."]
        var updateProps = agentFields
        updateProps["agent_name"] = ["type": "string", "description": "Current exact name of the agent to change."]
        updateProps["new_name"] = ["type": "string", "description": "New name, if renaming."]
        updateProps["make_main"] = ["type": "boolean", "description": "Make it the main agent (only one can be)."]

        return [
            [
                "name": "list_agents",
                "description": "List the user's agents with their settings, the group chats, and which AI providers and models the user has keys for. Call it before creating or changing agents.",
                "input_schema": [
                    "type": "object",
                    "properties": ["include_instructions": ["type": "boolean", "description": "Also return each agent's full instructions."]],
                ],
            ],
            [
                "name": "create_agent",
                "description": "Create a new agent for the user. Write rich, specific instructions tailored to what you learned about them. Tell the user what you created.",
                "input_schema": ["type": "object", "properties": createProps, "required": ["name", "instructions"]],
            ],
            [
                "name": "update_agent",
                "description": "Change an existing agent: any field you pass is replaced, the rest stay as they are.",
                "input_schema": ["type": "object", "properties": updateProps, "required": ["agent_name"]],
            ],
            [
                "name": "delete_agent",
                "description": "Delete an agent. Only after the user clearly asked for it or confirmed. Its chats stay.",
                "input_schema": [
                    "type": "object",
                    "properties": ["agent_name": ["type": "string", "description": "Exact name of the agent to delete."]],
                    "required": ["agent_name"],
                ],
            ],
            [
                "name": "create_group_chat",
                "description": "Create a group chat with 2-6 agents. The main agent leads it if it's a member.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "Chat name, e.g. Health Team."],
                        "agent_names": ["type": "array", "items": ["type": "string"], "description": "Names of the agents in it."],
                        "pinned": ["type": "boolean", "description": "Pin it to the top of the chat list."],
                    ],
                    "required": ["title", "agent_names"],
                ],
            ],
            [
                "name": "update_group_chat",
                "description": "Rename a group chat, add or remove members, or pin/unpin it.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "chat_title": ["type": "string", "description": "Current title of the group chat."],
                        "new_title": ["type": "string"],
                        "add_agents": ["type": "array", "items": ["type": "string"]],
                        "remove_agents": ["type": "array", "items": ["type": "string"]],
                        "pinned": ["type": "boolean"],
                    ],
                    "required": ["chat_title"],
                ],
            ],
        ]
    }
}

extension AgentEngine {
    /// Runs a team tool. Returns nil when `name` isn't one.
    func runTeamTool(_ name: String, input: [String: Any], agent: Agent,
                     conversation: Conversation) -> (text: String, isError: Bool)? {
        guard TeamTools.names.contains(name) else { return nil }
        guard agent.isMain else { return ("Only the main agent can manage the team.", true) }
        switch name {
        case "list_agents": return (listAgents(includeInstructions: input["include_instructions"] as? Bool ?? false), false)
        case "create_agent": return createAgent(input, in: conversation)
        case "update_agent": return updateAgent(input, by: agent, in: conversation)
        case "delete_agent": return deleteAgent(input, by: agent, in: conversation)
        case "create_group_chat": return createGroup(input, in: conversation)
        default: return updateGroup(input, in: conversation)
        }
    }

    // MARK: - Tools

    private func listAgents(includeInstructions: Bool) -> String {
        var lines = ["# Agents"]
        for agent in allAgents() {
            var line = "- \(agent.emoji) \(agent.name)\(agent.isMain ? " (main)" : "") [\(agent.team)] — \(agent.tagline)"
            line += "\n  provider: \(agent.provider), model: \(agent.model)"
            if agent.providerKind == .anthropic { line += ", effort: \(agent.effort)" }
            line += ", web_search: \(agent.webSearch), can_consult: \(agent.canConsult), color: \(agent.colorHex)"
            if includeInstructions { line += "\n  instructions:\n\(agent.instructions)" }
            lines.append(line)
        }

        let groups = allConversations().filter(\.isGroup)
        lines.append("\n# Group chats")
        if groups.isEmpty { lines.append("None yet.") }
        for group in groups {
            let names = agents(in: group).map(\.name).joined(separator: ", ")
            lines.append("- \(group.title)\(group.pinned ? " (pinned)" : ""): \(names)")
        }

        lines.append("\n# Providers the user has keys for")
        let configured = Provider.configured
        if configured.isEmpty { lines.append("None.") }
        for provider in configured {
            let models = ProviderSettings.models(for: provider)
            let shown = models.prefix(40).joined(separator: ", ")
            lines.append("- \(provider.rawValue) (\(provider.name)). Default model: \(ProviderSettings.defaultModel(for: provider)). Models: \(shown)\(models.count > 40 ? ", …" : "")")
        }
        return lines.joined(separator: "\n")
    }

    private func createAgent(_ input: [String: Any], in conversation: Conversation) -> (String, Bool) {
        guard let name = Self.string(input["name"]) else { return ("name is required.", true) }
        guard let instructions = Self.string(input["instructions"]) else { return ("instructions are required.", true) }
        if allAgents().contains(where: { Mentions.normalize($0.name) == Mentions.normalize(name) }) {
            return ("An agent called \(name) already exists. Pick another name or use update_agent.", true)
        }
        let existing = allAgents()
        let agent = Agent(name: name, emoji: "🤖", colorHex: Palette.colors[existing.count % Palette.colors.count],
                          team: "General", tagline: "", instructions: instructions,
                          sortOrder: (existing.map(\.sortOrder).max() ?? 0) + 1)
        // New agents run where the main agent runs unless told otherwise; that provider has a key.
        if let main = existing.first(where: \.isMain) {
            agent.provider = main.provider
            agent.model = main.model
        } else if let first = Provider.configured.first {
            agent.provider = first.rawValue
            agent.model = ProviderSettings.defaultModel(for: first)
        }
        if let error = apply(input, to: agent) { return (error, true) }
        context.insert(agent)
        append(ChatMessage(kind: .notice, text: "Created \(agent.emoji) \(agent.name)"), to: conversation)
        save()
        return ("Created \(agent.name) (\(agent.provider) / \(agent.model)).", false)
    }

    private func updateAgent(_ input: [String: Any], by caller: Agent, in conversation: Conversation) -> (String, Bool) {
        guard let wanted = Self.string(input["agent_name"]) else { return ("agent_name is required.", true) }
        guard let agent = Self.match(wanted, in: allAgents()) else { return (noAgent(wanted), true) }
        if let newName = Self.string(input["new_name"]) {
            if allAgents().contains(where: { $0.id != agent.id && Mentions.normalize($0.name) == Mentions.normalize(newName) }) {
                return ("Another agent is already called \(newName).", true)
            }
            agent.name = newName
        }
        if let instructions = Self.string(input["instructions"]) { agent.instructions = instructions }
        if let error = apply(input, to: agent) { return (error, true) }
        if input["make_main"] as? Bool == true {
            for other in allAgents() where other.id != agent.id { other.isMain = false }
            agent.isMain = true
        }
        append(ChatMessage(kind: .notice, text: "Updated \(agent.emoji) \(agent.name)"), to: conversation)
        save()
        return ("Updated \(agent.name).", false)
    }

    private func deleteAgent(_ input: [String: Any], by caller: Agent, in conversation: Conversation) -> (String, Bool) {
        guard let wanted = Self.string(input["agent_name"]) else { return ("agent_name is required.", true) }
        guard let agent = Self.match(wanted, in: allAgents()) else { return (noAgent(wanted), true) }
        if agent.id == caller.id { return ("You can't delete yourself. The user can do that from your settings.", true) }
        let label = "\(agent.emoji) \(agent.name)"
        context.delete(agent)
        append(ChatMessage(kind: .notice, text: "Deleted \(label)"), to: conversation)
        save()
        return ("Deleted \(label).", false)
    }

    private func createGroup(_ input: [String: Any], in conversation: Conversation) -> (String, Bool) {
        let names = (input["agent_names"] as? [Any] ?? []).compactMap(Self.string)
        var members: [Agent] = []
        for name in names {
            guard let agent = Self.match(name, in: allAgents()) else { return (noAgent(name), true) }
            if !members.contains(where: { $0.id == agent.id }) { members.append(agent) }
        }
        guard (2...6).contains(members.count) else { return ("A group chat needs 2 to 6 agents.", true) }
        let title = Self.string(input["title"]) ?? members.map(\.name).joined(separator: ", ")
        let group = Conversation(title: title, isGroup: true, memberIDs: members.map(\.id))
        group.pinned = input["pinned"] as? Bool ?? false
        context.insert(group)
        append(ChatMessage(kind: .notice, text: "Created group chat \(title)"), to: conversation)
        save()
        return ("Created the group chat \"\(title)\" with \(members.map(\.name).joined(separator: ", ")).", false)
    }

    private func updateGroup(_ input: [String: Any], in conversation: Conversation) -> (String, Bool) {
        guard let title = Self.string(input["chat_title"]) else { return ("chat_title is required.", true) }
        let groups = allConversations().filter(\.isGroup)
        guard let group = groups.first(where: { Mentions.normalize($0.title) == Mentions.normalize(title) }) else {
            return ("No group chat called \"\(title)\". Group chats: \(groups.map(\.title).joined(separator: ", ")).", true)
        }
        var ids = group.memberIDs
        for name in (input["add_agents"] as? [Any] ?? []).compactMap(Self.string) {
            guard let agent = Self.match(name, in: allAgents()) else { return (noAgent(name), true) }
            if !ids.contains(agent.id) { ids.append(agent.id) }
        }
        for name in (input["remove_agents"] as? [Any] ?? []).compactMap(Self.string) {
            if let agent = Self.match(name, in: allAgents()) { ids.removeAll { $0 == agent.id } }
        }
        guard (2...6).contains(ids.count) else { return ("A group chat needs 2 to 6 agents.", true) }
        group.memberIDs = ids
        if let newTitle = Self.string(input["new_title"]) { group.title = newTitle }
        if let pinned = input["pinned"] as? Bool { group.pinned = pinned }
        append(ChatMessage(kind: .notice, text: "Updated group chat \(group.title)"), to: conversation)
        save()
        return ("Updated \"\(group.title)\".", false)
    }

    // MARK: - Helpers

    /// Applies the optional agent fields. Returns an error message if a value isn't usable.
    private func apply(_ input: [String: Any], to agent: Agent) -> String? {
        if let raw = Self.string(input["provider"]) {
            guard let provider = Provider(rawValue: raw.lowercased()) else {
                return "Unknown provider \(raw). Use one of: \(Provider.allCases.map(\.rawValue).joined(separator: ", "))."
            }
            guard Keychain.key(for: provider) != nil else {
                let have = Provider.configured.map(\.rawValue).joined(separator: ", ")
                return "The user has no \(provider.name) key. Providers with keys: \(have.isEmpty ? "none" : have)."
            }
            if provider.rawValue != agent.provider {
                agent.provider = provider.rawValue
                agent.model = ProviderSettings.defaultModel(for: provider)
            }
        }
        if let model = Self.string(input["model"]) {
            let known = ProviderSettings.models(for: agent.providerKind)
            if !known.isEmpty && !known.contains(model) {
                return "\(model) isn't in the \(agent.providerKind.name) model list. Call list_agents to see the models."
            }
            agent.model = model
        }
        if let effort = Self.string(input["effort"]) {
            guard ModelCatalog.efforts.contains(effort) else { return "effort must be one of \(ModelCatalog.efforts.joined(separator: ", "))." }
            agent.effort = effort
        }
        if let emoji = Self.string(input["emoji"]), let first = emoji.first { agent.emoji = String(first) }
        if let color = Self.string(input["color"]), color.hasPrefix("#"), color.count == 7 { agent.colorHex = color.uppercased() }
        if let label = Self.string(input["label"]) { agent.team = label }
        if let tagline = Self.string(input["tagline"]) { agent.tagline = tagline }
        if let webSearch = input["web_search"] as? Bool { agent.webSearch = webSearch }
        if let canConsult = input["can_consult"] as? Bool { agent.canConsult = canConsult }
        return nil
    }

    private func noAgent(_ name: String) -> String {
        "No agent called \"\(name)\". Agents: \(allAgents().map(\.name).joined(separator: ", "))."
    }

    private func allConversations() -> [Conversation] {
        (try? context.fetch(FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    private static func string(_ value: Any?) -> String? {
        let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }
}

extension Agent {
    var providerKind: Provider { Provider.from(provider) }
}
