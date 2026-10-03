import SwiftUI
import SwiftData

struct ChatView: View {
    @Bindable var conversation: Conversation
    @Environment(AgentEngine.self) private var engine
    @Query(sort: [SortDescriptor(\Agent.sortOrder), SortDescriptor(\Agent.createdAt)]) private var allAgents: [Agent]
    @State private var draft = ""
    @State private var showInfo = false
    @State private var replyingTo: ChatMessage?
    @State private var selecting: ChatMessage?
    /// A provider whose key is here (e.g. synced through iCloud Keychain) but that this device
    /// hasn't been allowed to send chats to yet.
    @State private var consentFor: Provider?
    @FocusState private var inputFocused: Bool

    private var members: [Agent] {
        conversation.memberIDs.compactMap { id in allAgents.first { $0.id == id } }
    }

    private var title: String {
        if !conversation.isGroup, let agent = members.first { return agent.name }
        return conversation.title.isEmpty ? "Group" : conversation.title
    }

    private var visibleMessages: [ChatMessage] {
        conversation.sortedMessages.filter { $0.messageKind != .consult }
    }

    private var consultsByParent: [UUID: [ChatMessage]] {
        Dictionary(grouping: conversation.sortedMessages.filter { $0.messageKind == .consult && $0.parentID != nil },
                   by: { $0.parentID! })
    }

    /// Changes whenever new text streams in, to keep the view scrolled to the bottom.
    private var scrollKey: Int {
        conversation.sortedMessages.reduce(0) { $0 + $1.text.count + 1 }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if visibleMessages.isEmpty {
                        ChatIntro(conversation: conversation, members: members) { suggestion in
                            draft = suggestion
                            send()
                        }
                    }
                    ForEach(visibleMessages) { message in
                        MessageRow(message: message,
                                   agents: allAgents,
                                   consults: consultsByParent[message.id] ?? [],
                                   showName: conversation.isGroup,
                                   actions: actions(for: message))
                            .id(message.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: scrollKey) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if let replyingTo {
                    ReplyPreview(author: author(of: replyingTo), text: replyingTo.text) { self.replyingTo = nil }
                }
                InputBar(draft: $draft,
                     members: conversation.isGroup ? members : [],
                     isBusy: engine.isBusy(conversation),
                     focused: $inputFocused,
                     onSend: send,
                     onStop: { engine.stop(conversation) })
            }
        }
        .sheet(item: $selecting) { message in
            SelectTextView(text: message.text)
        }
        .alert("Send your chats to \(consentFor?.name ?? "")?",
               isPresented: Binding(get: { consentFor != nil }, set: { if !$0 { consentFor = nil } })) {
            Button("Allow") {
                if let consentFor { ProviderSettings.setConsent(true, for: consentFor) }
                consentFor = nil
                send()
            }
            Button("Cancel", role: .cancel) { consentFor = nil }
        } message: {
            if let consentFor { Text(ProviderSettings.consentText(for: consentFor)) }
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showInfo = true } label: { Image(systemName: "info.circle") }
            }
        }
        .sheet(isPresented: $showInfo) {
            if conversation.isGroup {
                GroupInfoView(conversation: conversation)
            } else if let agent = members.first {
                AgentEditorView(agent: agent)
            }
        }
    }

    private func send() {
        if let missing = Provider.configured.first(where: { !ProviderSettings.hasConsent($0) }) {
            consentFor = missing
            return
        }
        var text = draft
        if let replyingTo, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let quoted = replyingTo.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let short = quoted.count > 280 ? String(quoted.prefix(280)) + "…" : quoted
            let quote = short.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n")
            text = "Replying to \(author(of: replyingTo)):\n\(quote)\n\n\(text)"
        }
        draft = ""
        replyingTo = nil
        engine.send(text, in: conversation)
    }

    private func author(of message: ChatMessage) -> String {
        if message.messageKind == .user { return "you" }
        return allAgents.first { $0.id == message.agentID }?.name ?? "Agent"
    }

    /// The long-press / right-click actions for one message.
    private func actions(for message: ChatMessage) -> MessageActions {
        let busy = engine.isBusy(conversation)
        let lastAgentReply = visibleMessages.last(where: { $0.messageKind == .agent })
        return MessageActions(
            reply: { replyingTo = message; inputFocused = true },
            select: { selecting = message },
            edit: message.messageKind == .user ? { draft = message.text; inputFocused = true } : nil,
            retry: (!busy && message.messageKind == .agent && message.id == lastAgentReply?.id)
                ? { engine.regenerate(in: conversation) } : nil,
            delete: busy ? nil : { engine.delete(message, in: conversation) }
        )
    }
}

// MARK: - Message actions

/// What the long-press menu on a message can do. nil hides that action.
struct MessageActions {
    var reply: () -> Void = {}
    var select: () -> Void = {}
    var edit: (() -> Void)?
    var retry: (() -> Void)?
    var delete: (() -> Void)?
}

enum Clipboard {
    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

/// The message being replied to, shown above the text field.
private struct ReplyPreview: View {
    let author: String
    let text: String
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Replying to \(author)").font(.caption.weight(.semibold))
                Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button(action: onCancel) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
        }
        .frame(height: 40)
        .padding(.horizontal)
        .padding(.top, 8)
        .background(.bar)
    }
}

/// Full message text where any part can be selected and copied.
private struct SelectTextView: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Select Text")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { Clipboard.copy(text) } label: { Label("Copy All", systemImage: "doc.on.doc") }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 400)
        #endif
    }
}

// MARK: - Intro

private struct ChatIntro: View {
    let conversation: Conversation
    let members: [Agent]
    let onSuggestion: (String) -> Void

    private var suggestions: [String] {
        if conversation.isGroup {
            return ["Build my ideal day for tomorrow", "@everyone what's the one change that would help me most right now?",
                    "Plan my meals and workouts for this week"]
        }
        switch members.first?.seedKey {
        case "chief": return ["Build me a team of agents", "What can you do for me?", "Ask me questions to get to know me"]
        #if DEBUG
        case "dont-die": return ["Build my Don't Die protocol", "What should I measure first?", "Review my sleep routine"]
        case "nutrition": return ["Plan a full day of fruitarian meals", "Am I missing any nutrients?", "What bloodwork should I get?"]
        case "workouts": return ["Make me a weekly training plan", "A 30-minute workout I can do at home", "How do I improve my VO2 max?"]
        case "daily-coach": return ["What should I do today?", "Design my morning routine", "Help me build an evening wind-down"]
        case "youtube-scout": return ["Find 5 video ideas for my channel", "What's trending in my niche this week?", "Research outlier videos for me"]
        #endif
        default: return ["What can you help me with?", "Ask me questions to get to know me"]
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            if conversation.isGroup {
                GroupAvatar(agents: members, size: 72)
                Text(conversation.title).font(.title2.bold())
                Text("Talk to the whole team. @mention an agent to ask them directly, or @everyone to hear from all.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            } else if let agent = members.first {
                AgentAvatar(agent: agent, size: 72)
                Text(agent.name).font(.title2.bold())
                Text(agent.tagline).multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
            VStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button { onSuggestion(suggestion) } label: {
                        Text(suggestion)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .padding(.horizontal, 12)
                            .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .padding(.horizontal, 12)
    }
}

// MARK: - Message row

struct MessageRow: View {
    let message: ChatMessage
    let agents: [Agent]
    let consults: [ChatMessage]
    let showName: Bool
    var actions = MessageActions()
    @Environment(AgentEngine.self) private var engine

    private func agent(_ id: UUID?) -> Agent? {
        guard let id else { return nil }
        return agents.first { $0.id == id }
    }

    var body: some View {
        switch message.messageKind {
        case .user:
            HStack {
                Spacer(minLength: 48)
                MarkdownText(text: message.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 18).fill(Color.accentColor.opacity(0.18)))
                    #if os(iOS)
                    .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 18))
                    #endif
                    .contextMenu { menu }
            }
        case .agent:
            agentReply
                .contentShape(Rectangle())
                .contextMenu { if !engine.streamingMessages.contains(message.id) { menu } }
        case .handoff:
            let from = agent(message.fromAgentID)
            let to = agent(message.agentID)
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right")
                Text("\(from?.name ?? "Agent") handed off to \(to?.name ?? "Agent")")
                    .fontWeight(.medium)
                if !message.question.isEmpty {
                    Text("· \(message.question)").lineLimit(2)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
        case .notice:
            Label(message.text, systemImage: Self.isTeamChange(message.text) ? "sparkles" : "exclamationmark.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        case .consult:
            EmptyView()
        }
    }

    private static func isTeamChange(_ text: String) -> Bool {
        ["Created ", "Updated ", "Deleted "].contains { text.hasPrefix($0) }
    }

    @ViewBuilder private var menu: some View {
        if !message.text.isEmpty {
            Button { Clipboard.copy(message.text) } label: { Label("Copy", systemImage: "doc.on.doc") }
            Button(action: actions.reply) { Label("Reply", systemImage: "arrowshape.turn.up.left") }
            ShareLink(item: message.text) { Label("Share", systemImage: "square.and.arrow.up") }
            Button(action: actions.select) { Label("Select Text", systemImage: "selection.pin.in.out") }
        }
        if let edit = actions.edit {
            Button(action: edit) { Label("Edit and Resend", systemImage: "pencil") }
        }
        if let retry = actions.retry {
            Button(action: retry) { Label("Retry", systemImage: "arrow.clockwise") }
        }
        if let delete = actions.delete {
            Divider()
            Button(role: .destructive, action: delete) { Label("Delete", systemImage: "trash") }
        }
    }

    private var agentReply: some View {
        let author = agent(message.agentID)
        let streaming = engine.streamingMessages.contains(message.id)
        let status = engine.status[message.id] ?? ""
        return HStack(alignment: .top, spacing: 10) {
            AgentAvatar(agent: author, size: 32)
            VStack(alignment: .leading, spacing: 8) {
                if showName || !consults.isEmpty {
                    Text(author?.name ?? "Agent")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(hex: author?.colorHex ?? "#8D8D8D"))
                }
                if !consults.isEmpty {
                    TeamActivityPanel(consults: consults, agents: agents)
                }
                if !message.thinking.isEmpty {
                    DisclosureGroup {
                        Text(message.thinking)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } label: {
                        Label("Reasoning", systemImage: "brain").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !message.text.isEmpty {
                    MarkdownText(text: message.text)
                }
                if streaming {
                    HStack(spacing: 8) {
                        TypingIndicator()
                        if !status.isEmpty {
                            Text(status).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !message.sources.isEmpty {
                    SourcesView(sources: message.sources)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Grok-style panel: who the agent consulted, what they asked, and each teammate's answer.
struct TeamActivityPanel: View {
    let consults: [ChatMessage]
    let agents: [Agent]
    @Environment(AgentEngine.self) private var engine
    @State private var expanded = false

    private func agent(_ id: UUID?) -> Agent? {
        guard let id else { return nil }
        return agents.first { $0.id == id }
    }

    var body: some View {
        let working = consults.contains { engine.streamingMessages.contains($0.id) }
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    HStack(spacing: -8) {
                        ForEach(consults) { consult in
                            AgentAvatar(agent: agent(consult.agentID), size: 22)
                        }
                    }
                    Text(working ? "Consulting the team…" : "Consulted \(consults.count) \(consults.count == 1 ? "agent" : "agents")")
                        .font(.caption.weight(.medium))
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ForEach(consults) { consult in
                    let asker = agent(consult.fromAgentID)
                    let target = agent(consult.agentID)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            AgentAvatar(agent: target, size: 20)
                            Text("\(asker?.name ?? "Agent") → \(target?.name ?? "Agent")")
                                .font(.caption.weight(.semibold))
                            if engine.streamingMessages.contains(consult.id) {
                                TypingIndicator()
                            }
                        }
                        Text(consult.question)
                            .font(.caption)
                            .italic()
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                        if !consult.text.isEmpty {
                            MarkdownText(text: consult.text).font(.footnote)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: target?.colorHex ?? "#8D8D8D").opacity(0.08)))
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    }
}

struct SourcesView: View {
    let sources: [ChatMessage.Source]
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(sources, id: \.url) { source in
                    if let url = URL(string: source.url) {
                        Link(destination: url) {
                            Text(source.title).font(.caption).lineLimit(1)
                        }
                    }
                }
            }
        } label: {
            Label("\(sources.count) sources", systemImage: "globe").font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Input

struct InputBar: View {
    @Binding var draft: String
    let members: [Agent]
    let isBusy: Bool
    var focused: FocusState<Bool>.Binding
    let onSend: () -> Void
    let onStop: () -> Void

    /// Agents matching an "@" the user is currently typing.
    private var mentionMatches: [Agent] {
        guard !members.isEmpty, let lastWord = draft.split(separator: " ", omittingEmptySubsequences: false).last,
              lastWord.hasPrefix("@") else { return [] }
        let query = Mentions.normalize(String(lastWord.dropFirst()))
        return members.filter { query.isEmpty || Mentions.normalize($0.name).hasPrefix(query) }
    }

    var body: some View {
        VStack(spacing: 8) {
            if !mentionMatches.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(mentionMatches) { agent in
                            Button { insertMention(agent.name) } label: {
                                HStack(spacing: 4) {
                                    Text(agent.emoji)
                                    Text(agent.name).font(.subheadline)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(.quaternary))
                            }
                            .buttonStyle(.plain)
                        }
                        Button { insertMention("everyone") } label: {
                            Text("@everyone").font(.subheadline)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(.quaternary))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(members.isEmpty ? "Message" : "Message the team… (@ to mention)", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .focused(focused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 20).fill(.quaternary))
                    .onSubmit {
                        #if os(macOS)
                        if !isBusy { onSend() }
                        #endif
                    }
                if isBusy {
                    Button(action: onStop) {
                        Image(systemName: "stop.circle.fill").font(.system(size: 32))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                } else {
                    Button(action: onSend) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func insertMention(_ name: String) {
        var words = draft.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        if !words.isEmpty { words.removeLast() }
        words.append("@\(name) ")
        draft = words.joined(separator: " ")
    }
}
