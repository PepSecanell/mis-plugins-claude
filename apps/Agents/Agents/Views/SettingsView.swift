import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var agents: [Agent]
    @State private var confirmRestore = false
    /// Bumped when a key changes so the provider list re-reads the Keychain.
    @State private var refresh = 0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(Provider.allCases) { provider in
                        NavigationLink {
                            ProviderKeyView(provider: provider) { refresh += 1 }
                        } label: {
                            HStack {
                                Text(provider.name)
                                Spacer()
                                if Keychain.key(for: provider) != nil {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                }
                            }
                        }
                    }
                    .id(refresh)
                } header: {
                    Text("AI providers")
                } footer: {
                    Text("Add an API key from any of these. Each agent can run on any provider you've added. Keys stay in your Keychain and sync to your other devices with iCloud Keychain. You pay the provider directly.")
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
                    Button("Restore built-in agents") { confirmRestore = true }
                } footer: {
                    Text("Adds back any built-in agent you deleted, like \(SeedData.starterAgents().map(\.name).joined(separator: ", ")).")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Restore built-in agents?", isPresented: $confirmRestore) {
                Button("Restore") { restoreStarters() }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
    }

    private func restoreStarters() {
        let existing = Set(agents.map(\.seedKey))
        for agent in SeedData.starterAgents() where !existing.contains(agent.seedKey) {
            if agent.isMain && agents.contains(where: \.isMain) { agent.isMain = false }
            if Keychain.key(for: agent.providerKind) == nil, let provider = Provider.configured.first {
                agent.provider = provider.rawValue
                agent.model = ProviderSettings.defaultModel(for: provider)
            }
            context.insert(agent)
        }
        try? context.save()
    }
}

/// Add, check and remove one provider's API key, and pick its default model.
struct ProviderKeyView: View {
    let provider: Provider
    var onChange: () -> Void = {}

    @Environment(\.modelContext) private var context
    @Query private var agents: [Agent]
    @State private var key = ""
    @State private var hasKey = false
    @State private var checking = false
    @State private var error: String?
    @State private var models: [String] = []
    @State private var defaultModel = ""
    @State private var askConsent = false
    @State private var movedAll = false

    var body: some View {
        Form {
            Section {
                SecureField(provider.keyPlaceholder, text: $key)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                Button {
                    if ProviderSettings.hasConsent(provider) {
                        Task { await saveKey() }
                    } else {
                        askConsent = true
                    }
                } label: {
                    if checking {
                        HStack { ProgressView(); Text("Checking…") }
                    } else {
                        Text(hasKey ? "Update key" : "Save key")
                    }
                }
                .disabled(checking || key.trimmingCharacters(in: .whitespaces).isEmpty)
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                Link("Get a key from \(provider.shortName)", destination: provider.keyPage)
            } header: {
                Text("\(provider.name) API key")
            } footer: {
                Text(ProviderSettings.consentText(for: provider))
            }

            if hasKey {
                Section {
                    if models.isEmpty {
                        Text("No models found for this key.").foregroundStyle(.secondary)
                    } else {
                        Picker("Default model", selection: $defaultModel) {
                            ForEach(models, id: \.self) { Text(ModelCatalog.label(for: $0)).tag($0) }
                        }
                        .onChange(of: defaultModel) { _, value in
                            ProviderSettings.setDefaultModel(value, for: provider)
                        }
                    }
                    Button("Refresh model list") { Task { await refreshModels() } }
                } footer: {
                    Text("New agents on \(provider.shortName) use this model. You can change it per agent.")
                }

                Section {
                    Button("Use \(provider.shortName) for all agents") {
                        ProviderRouting.moveAll(to: provider, in: context)
                        movedAll = true
                    }
                    .disabled(models.isEmpty && provider != .anthropic)
                    if movedAll {
                        Text("All agents now use \(provider.shortName) (\(ModelCatalog.label(for: defaultModel))).")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Or change one agent at a time from its settings.")
                }

                Section {
                    Button("Remove key", role: .destructive) {
                        Keychain.setKey(nil, for: provider)
                        hasKey = false
                        key = ""
                        // Agents on this provider move to one that still has a key.
                        Task { await ProviderRouting.repairAll(in: context) }
                        onChange()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(provider.name)
        .alert("Send your chats to \(provider.name)?", isPresented: $askConsent) {
            Button("Allow") {
                ProviderSettings.setConsent(true, for: provider)
                Task { await saveKey() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(ProviderSettings.consentText(for: provider))
        }
        .onAppear(perform: load)
        .task {
            // A key synced from another device has no model list on this one yet.
            if Keychain.key(for: provider) != nil && models.isEmpty && provider != .anthropic { await refreshModels() }
        }
    }

    private func load() {
        let saved = Keychain.key(for: provider)
        hasKey = saved != nil
        key = saved ?? ""
        models = ProviderSettings.models(for: provider)
        defaultModel = ProviderSettings.defaultModel(for: provider)
    }

    /// Checks the key by listing its models, then saves it. A rejected key is never stored.
    private func saveKey() async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        checking = true
        error = nil
        defer { checking = false }
        do {
            let fetched = try await ProviderSettings.fetchModels(for: provider, apiKey: trimmed)
            let hadPreferred = ProviderSettings.preferred != nil
            Keychain.setKey(trimmed, for: provider)
            if provider != .anthropic { ProviderSettings.setModels(fetched, for: provider) }
            hasKey = true
            models = ProviderSettings.models(for: provider)
            if !models.contains(defaultModel) { defaultModel = ProviderSettings.defaultModel(for: provider) }
            if !models.contains(defaultModel) { defaultModel = models.first ?? "" }
            ProviderSettings.setDefaultModel(defaultModel, for: provider)
            if !hadPreferred { ProviderSettings.setPreferred(provider) }
            // Agents on a provider with no key (or with no model yet) move here right away.
            await ProviderRouting.repairAll(in: context)
            onChange()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func refreshModels() async {
        guard let saved = Keychain.key(for: provider) else { return }
        do {
            let fetched = try await ProviderSettings.fetchModels(for: provider, apiKey: saved)
            if provider != .anthropic { ProviderSettings.setModels(fetched, for: provider) }
            models = ProviderSettings.models(for: provider)
            if !models.contains(defaultModel) { defaultModel = ProviderSettings.defaultModel(for: provider) }
            if !models.contains(defaultModel) { defaultModel = models.first ?? "" }
            ProviderSettings.setDefaultModel(defaultModel, for: provider)
        } catch {
            self.error = error.localizedDescription
        }
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
