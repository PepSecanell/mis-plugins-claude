import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var context
    @State private var selection: Conversation?

    var body: some View {
        NavigationSplitView {
            HomeView(selection: $selection)
                #if os(macOS)
                .navigationSplitViewColumnWidth(min: 280, ideal: 320)
                #endif
        } detail: {
            if let selection {
                ChatView(conversation: selection)
                    .id(selection.id)
            } else {
                ContentUnavailableView("Pick an agent or a chat",
                                       systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Talk to one agent, or to the whole team in a group chat."))
            }
        }
        #if DEBUG
        .task {
            // Screenshot mode: open the chat named by `-demoOpen`.
            guard DemoContent.isEnabled, let title = UserDefaults.standard.string(forKey: "demoOpen") else { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            selection = try? context.fetch(FetchDescriptor<Conversation>()).first { $0.title == title }
        }
        #endif
    }
}

struct HomeView: View {
    @Binding var selection: Conversation?
    @Environment(\.modelContext) private var context
    @Environment(AgentEngine.self) private var engine
    @Query(sort: [SortDescriptor(\Agent.sortOrder), SortDescriptor(\Agent.createdAt)]) private var agents: [Agent]
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]

    @State private var showNewAgent = false
    @State private var showNewGroup = false
    @State private var showSettings = false
    @State private var editingAgent: Agent?

    private var sortedConversations: [Conversation] {
        conversations.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    var body: some View {
        List(selection: $selection) {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(agents) { agent in
                            Button { openDirectChat(with: agent) } label: {
                                VStack(spacing: 4) {
                                    AgentAvatar(agent: agent, size: 54)
                                        .overlay(alignment: .bottomTrailing) {
                                            if agent.isMain {
                                                Image(systemName: "star.circle.fill")
                                                    .foregroundStyle(Color.yellow, Color.black.opacity(0.6))
                                                    .font(.system(size: 16))
                                            }
                                        }
                                    Text(agent.name)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .frame(width: 66)
                                }
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Chat", systemImage: "bubble.left") { openDirectChat(with: agent) }
                                Button("Edit agent", systemImage: "pencil") { editingAgent = agent }
                            }
                        }
                        Button { showNewAgent = true } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "plus")
                                    .font(.title2)
                                    .frame(width: 54, height: 54)
                                    .background(Circle().strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4])))
                                    .foregroundStyle(.secondary)
                                Text("New").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 6)
                }
            } header: {
                Text("Agents")
            }

            Section("Chats") {
                if sortedConversations.isEmpty {
                    Text("Tap an agent above to start chatting.")
                        .foregroundStyle(.secondary)
                }
                ForEach(sortedConversations) { conversation in
                    NavigationLink(value: conversation) {
                        ConversationRow(conversation: conversation, agents: agents)
                    }
                    .swipeActions(edge: .leading) {
                        Button(conversation.pinned ? "Unpin" : "Pin",
                               systemImage: conversation.pinned ? "pin.slash" : "pin") {
                            conversation.pinned.toggle()
                        }
                        .tint(.orange)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", systemImage: "trash", role: .destructive) { delete(conversation) }
                    }
                    .contextMenu {
                        Button(conversation.pinned ? "Unpin" : "Pin", systemImage: "pin") { conversation.pinned.toggle() }
                        Button("Delete", systemImage: "trash", role: .destructive) { delete(conversation) }
                    }
                }
            }
        }
        .navigationTitle("Agent Teams")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("New Agent", systemImage: "person.crop.circle.badge.plus") { showNewAgent = true }
                    Button("New Group Chat", systemImage: "person.3") { showNewGroup = true }
                } label: {
                    Image(systemName: "plus")
                }
            }
            ToolbarItem(placement: .navigation) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
        }
        .sheet(isPresented: $showNewAgent) {
            AgentEditorView(agent: nil) { created in
                if let created { openDirectChat(with: created) }
            }
        }
        .sheet(item: $editingAgent) { agent in
            AgentEditorView(agent: agent)
        }
        .sheet(isPresented: $showNewGroup) {
            NewGroupView { group in selection = group }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }

    private func openDirectChat(with agent: Agent) {
        if let existing = conversations.first(where: { !$0.isGroup && $0.memberIDs == [agent.id] }) {
            selection = existing
            return
        }
        let chat = Conversation(title: agent.name, isGroup: false, memberIDs: [agent.id])
        context.insert(chat)
        try? context.save()
        selection = chat
    }

    private func delete(_ conversation: Conversation) {
        if selection == conversation { selection = nil }
        engine.stop(conversation)
        context.delete(conversation)
        try? context.save()
    }
}

struct ConversationRow: View {
    let conversation: Conversation
    let agents: [Agent]

    private var members: [Agent] {
        conversation.memberIDs.compactMap { id in agents.first { $0.id == id } }
    }

    private var title: String {
        if !conversation.isGroup, let agent = members.first { return agent.name }
        return conversation.title.isEmpty ? members.map(\.name).joined(separator: ", ") : conversation.title
    }

    private var preview: String {
        guard let last = conversation.lastMessage else {
            return conversation.isGroup ? "\(members.count) agents" : (members.first?.tagline ?? "")
        }
        // Plain text for the one-line preview: drop markdown markers like **bold** and # headings.
        let plain = (try? AttributedString(markdown: last.text,
                                           options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            .map { String($0.characters) } ?? last.text
        let text = plain.replacingOccurrences(of: "\n", with: " ")
        switch last.messageKind {
        case .user:
            return "You: " + text
        case .agent where conversation.isGroup:
            let name = agents.first { $0.id == last.agentID }?.name ?? "Agent"
            return "\(name): " + text
        case .handoff:
            return "Handed off"
        default:
            return text
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            if conversation.isGroup {
                GroupAvatar(agents: members)
            } else {
                AgentAvatar(agent: members.first, size: 44)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).font(.headline).lineLimit(1)
                    if conversation.pinned {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange)
                    }
                    Spacer()
                    Text(conversation.updatedAt, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}
