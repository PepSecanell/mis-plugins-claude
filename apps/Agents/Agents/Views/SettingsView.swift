import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var agents: [Agent]
    @State private var apiKey = ""
    @State private var savedKey = false
    @State private var confirmRestore = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("sk-ant-…", text: $apiKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                    Button(savedKey ? "Saved ✓" : "Save key") {
                        Keychain.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        savedKey = true
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    Link("Get an API key at console.anthropic.com",
                         destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                } header: {
                    Text("Anthropic API key")
                } footer: {
                    Text("Stored in your Keychain and synced to your other Apple devices with iCloud Keychain. You pay Anthropic directly for what the agents use.")
                }

                Section {
                    NavigationLink {
                        MemoryView()
                    } label: {
                        Label("About me (shared memory)", systemImage: "brain.head.profile")
                    }
                } footer: {
                    Text("Facts every agent knows about you. Agents add to it as you chat, and you can edit it.")
                }

                Section {
                    Button("Restore starter agents") { confirmRestore = true }
                } footer: {
                    Text("Adds back any of the built-in agents (Don't Die, Nutrition, Workouts, Daily Coach, YouTube Scout) you deleted.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Restore starter agents?", isPresented: $confirmRestore) {
                Button("Restore") { restoreStarters() }
            }
            .onAppear {
                apiKey = Keychain.apiKey ?? ""
            }
            .onChange(of: apiKey) { savedKey = false }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 440)
        #endif
    }

    private func restoreStarters() {
        let existing = Set(agents.map(\.seedKey))
        for agent in SeedData.starterAgents() where !existing.contains(agent.seedKey) {
            if agent.isMain && agents.contains(where: \.isMain) { agent.isMain = false }
            context.insert(agent)
        }
        try? context.save()
    }
}

struct MemoryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \MemoryItem.createdAt) private var memories: [MemoryItem]
    @State private var newFact = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Add a fact about you…", text: $newFact)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(newFact.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Section {
                if memories.isEmpty {
                    Text("Nothing yet. Tell your agents about yourself, like your age, goals, diet and routine, and they'll remember.")
                        .foregroundStyle(.secondary)
                }
                ForEach(memories) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.text)
                        Text("\(item.sourceAgentName) · \(item.createdAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contextMenu {
                        Button("Delete", role: .destructive) { context.delete(item) }
                    }
                }
                .onDelete { offsets in
                    for index in offsets { context.delete(memories[index]) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("About Me")
    }

    private func add() {
        let text = newFact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        context.insert(MemoryItem(text: text, sourceAgentName: "You"))
        newFact = ""
        try? context.save()
    }
}
