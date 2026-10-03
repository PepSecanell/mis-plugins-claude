import SwiftUI
import SwiftData

/// Create a new agent or edit an existing one.
struct AgentEditorView: View {
    let agent: Agent?
    var onSave: (Agent?) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(AgentEngine.self) private var engine
    @Query private var allAgents: [Agent]

    @State private var name = ""
    @State private var emoji = "🤖"
    @State private var colorHex = Palette.colors[6]
    @State private var team = "General"
    @State private var tagline = ""
    @State private var instructions = ""
    @State private var model = ModelCatalog.defaultModel
    @State private var effort = "medium"
    @State private var webSearch = false
    @State private var canConsult = true
    @State private var isMain = false

    @State private var aiDescription = ""
    @State private var drafting = false
    @State private var draftError: String?
    @State private var confirmDelete = false

    private var isNew: Bool { agent == nil }
    private var teams: [String] {
        Array(Set(allAgents.map(\.team) + ["Health", "YouTube", "General"])).sorted()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        AgentAvatar(emoji: emoji, colorHex: colorHex, size: 64)
                        VStack(alignment: .leading) {
                            TextField("Name", text: $name).font(.title3.weight(.semibold))
                            TextField("Emoji", text: $emoji)
                                .onChange(of: emoji) { _, value in
                                    if value.count > 1, let last = value.last { emoji = String(last) }
                                }
                        }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(Palette.colors, id: \.self) { hex in
                                Circle()
                                    .fill(Color(hex: hex))
                                    .frame(width: 28, height: 28)
                                    .overlay(Circle().strokeBorder(.primary, lineWidth: hex == colorHex ? 2 : 0))
                                    .onTapGesture { colorHex = hex }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("Label") {
                    TextField("Team or topic, e.g. Health", text: $team)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(teams, id: \.self) { option in
                                Button(option) { team = option }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                    }
                }

                Section {
                    TextField("Describe what this agent should do…", text: $aiDescription, axis: .vertical)
                        .lineLimit(2...5)
                    Button {
                        Task { await draftWithAI() }
                    } label: {
                        if drafting {
                            HStack { ProgressView(); Text("Writing…") }
                        } else {
                            Label("Write instructions with AI", systemImage: "sparkles")
                        }
                    }
                    .disabled(drafting || aiDescription.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let draftError {
                        Text(draftError).font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("Quick start")
                } footer: {
                    Text("Describe the agent in a sentence and Claude writes its tagline and instructions. You can edit them after.")
                }

                Section {
                    TextField("One line: what it's great at", text: $tagline, axis: .vertical)
                        .lineLimit(1...3)
                } header: {
                    Text("Specialty")
                } footer: {
                    Text("Teammates see this when deciding whether to consult this agent.")
                }

                Section("Instructions") {
                    TextEditor(text: $instructions)
                        .frame(minHeight: 220)
                        .font(.callout)
                }

                Section {
                    Picker("Model", selection: $model) {
                        ForEach(ModelCatalog.options) { option in
                            VStack(alignment: .leading) {
                                Text(option.label)
                                Text(option.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(option.id)
                        }
                    }
                    if ModelCatalog.supportsAdaptiveThinking(model) {
                        Picker("Thinking effort", selection: $effort) {
                            ForEach(ModelCatalog.efforts, id: \.self) { Text($0.capitalized).tag($0) }
                        }
                    }
                    Toggle("Web search", isOn: $webSearch)
                    Toggle("Can consult other agents", isOn: $canConsult)
                    Toggle("Main agent", isOn: $isMain)
                } header: {
                    Text("Abilities")
                } footer: {
                    Text("Higher effort thinks longer: better answers, slower and more expensive. Web search costs about $0.01 per search. The main agent leads group chats and coordinates the team.")
                }

                if !isNew {
                    Section {
                        Button("Delete Agent", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isNew ? "New Agent" : "Edit Agent")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Create" : "Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("Delete \(name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { deleteAgent() }
            } message: {
                Text("Chats with this agent stay, but it will stop replying.")
            }
            .onAppear(perform: load)
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 640)
        #endif
    }

    private func load() {
        guard let agent else { return }
        name = agent.name
        emoji = agent.emoji
        colorHex = agent.colorHex
        team = agent.team
        tagline = agent.tagline
        instructions = agent.instructions
        model = agent.model
        effort = agent.effort
        webSearch = agent.webSearch
        canConsult = agent.canConsult
        isMain = agent.isMain
    }

    private func draftWithAI() async {
        drafting = true
        draftError = nil
        defer { drafting = false }
        do {
            let result = try await engine.draftAgent(name: name.isEmpty ? "Agent" : name, description: aiDescription)
            if !result.tagline.isEmpty { tagline = result.tagline }
            instructions = result.instructions
        } catch {
            draftError = error.localizedDescription
        }
    }

    private func save() {
        let target: Agent
        if let agent {
            target = agent
        } else {
            target = Agent(name: name, emoji: emoji, colorHex: colorHex, team: team, tagline: tagline,
                           instructions: instructions, sortOrder: (allAgents.map(\.sortOrder).max() ?? 0) + 1)
            context.insert(target)
        }
        target.name = name.trimmingCharacters(in: .whitespaces)
        target.emoji = emoji.isEmpty ? "🤖" : emoji
        target.colorHex = colorHex
        target.team = team.trimmingCharacters(in: .whitespaces).isEmpty ? "General" : team
        target.tagline = tagline
        target.instructions = instructions
        target.model = model
        target.effort = effort
        target.webSearch = webSearch
        target.canConsult = canConsult
        if isMain {
            for other in allAgents where other.id != target.id { other.isMain = false }
        }
        target.isMain = isMain
        try? context.save()
        onSave(isNew ? target : nil)
        dismiss()
    }

    private func deleteAgent() {
        guard let agent else { return }
        engine.stopAll()
        context.delete(agent)
        try? context.save()
        dismiss()
    }
}
