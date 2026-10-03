import SwiftUI
import SwiftData

struct NewGroupView: View {
    var onCreate: (Conversation) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\Agent.sortOrder), SortDescriptor(\Agent.createdAt)]) private var agents: [Agent]
    @State private var title = ""
    @State private var selected: [UUID] = []

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. YouTube Crew", text: $title)
                }
                Section {
                    MemberPicker(agents: agents, selected: $selected)
                } header: {
                    Text("Agents")
                } footer: {
                    Text("Pick 2–6 agents. The main agent (or the first one) leads and can hand off to the others.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New Group Chat")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        let names = agents.filter { selected.contains($0.id) }.map(\.name)
                        let group = Conversation(title: title.isEmpty ? names.joined(separator: ", ") : title,
                                                 isGroup: true, memberIDs: selected)
                        context.insert(group)
                        try? context.save()
                        onCreate(group)
                        dismiss()
                    }
                    .disabled(selected.count < 2)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }
}

struct GroupInfoView: View {
    @Bindable var conversation: Conversation
    @Environment(\.dismiss) private var dismiss
    @Query(sort: [SortDescriptor(\Agent.sortOrder), SortDescriptor(\Agent.createdAt)]) private var agents: [Agent]
    @State private var selected: [UUID] = []

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Group name", text: $conversation.title)
                }
                Section("Agents") {
                    MemberPicker(agents: agents, selected: $selected)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Group Info")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        conversation.memberIDs = selected
                        dismiss()
                    }
                    .disabled(selected.isEmpty)
                }
            }
            .onAppear { selected = conversation.memberIDs }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }
}

private struct MemberPicker: View {
    let agents: [Agent]
    @Binding var selected: [UUID]

    var body: some View {
        ForEach(agents) { agent in
            Button {
                if let index = selected.firstIndex(of: agent.id) {
                    selected.remove(at: index)
                } else if selected.count < 6 {
                    selected.append(agent.id)
                }
            } label: {
                HStack(spacing: 12) {
                    AgentAvatar(agent: agent, size: 34)
                    VStack(alignment: .leading) {
                        Text(agent.name).foregroundStyle(.primary)
                        Text(agent.tagline).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: selected.contains(agent.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected.contains(agent.id) ? Color.accentColor : .secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}
