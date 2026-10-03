#if DEBUG
import Foundation
import SwiftData

/// End-to-end check against the real APIs with the keys saved on this device.
/// Debug builds only, launched with `-selfTest YES`. Uses a throwaway in-memory store, writes a
/// report to the app's temporary folder (never any key) and quits.
enum SelfTest {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "selfTest") }
    /// Lets the test run without touching the user's saved consent choices.
    nonisolated(unsafe) static var assumeConsent = false

    @MainActor
    static func run(context: ModelContext) async {
        assumeConsent = true
        var report: [String] = []
        func log(_ line: String) { report.append(line); print("[selftest] \(line)") }

        let configured = Provider.configured
        log("Providers with a key: \(configured.map(\.rawValue).joined(separator: ", "))")
        var failures = 0

        for provider in configured {
            log("")
            log("=== \(provider.name)")
            try? context.delete(model: ChatMessage.self)
            try? context.delete(model: Conversation.self)
            try? context.delete(model: Agent.self)
            await ProviderSettings.ensureModels(for: provider)
            // `-selfTestModel <id>` tests one specific model instead of the default.
            let forced = UserDefaults.standard.string(forKey: "selfTestModel") ?? ""
            let model = forced.isEmpty ? ProviderSettings.defaultModel(for: provider) : forced
            log("default model: \(model)  (\(ProviderSettings.models(for: provider).count) models listed)")

            let chief = SeedData.mainAgent()
            chief.provider = provider.rawValue
            chief.model = model
            context.insert(chief)
            let chat = Conversation(title: "Chief", isGroup: false, memberIDs: [chief.id])
            context.insert(chat)
            try? context.save()
            let engine = AgentEngine(context: context)

            await turn(engine, chat, """
                Create two agents for me right now, no questions: a running coach called Runner and a \
                nutritionist called Plate. Then make a group chat called Fit Team with Chief, Runner and Plate. \
                Then tell me in one sentence what you did.
                """)
            failures += check(chat, engine, log)
            let names = engine.allAgents().map { "\($0.name)(\($0.provider)/\($0.model))" }
            log("agents: \(names.joined(separator: ", "))")
            let groups = ((try? context.fetch(FetchDescriptor<Conversation>())) ?? []).filter(\.isGroup)
            log("group chats: \(groups.map(\.title).joined(separator: ", "))")
            if engine.allAgents().count < 3 || groups.isEmpty { failures += 1; log("FAIL: team not created") }

            if let group = groups.first {
                await turn(engine, group, "@everyone one tip each for my first week, one short sentence.")
                failures += check(group, engine, log)
                await turn(engine, group, "Runner, ask Plate what I should eat before a run, then answer me.")
                failures += check(group, engine, log)
                engine.regenerate(in: group)
                while engine.isBusy(group) { try? await Task.sleep(nanoseconds: 300_000_000) }
                failures += check(group, engine, log, label: "retry")
            }
            // A second turn in the 1-on-1 chat replays history (text only) to the same provider.
            await turn(engine, chat, "Thanks! Now rename Plate to Fuel.")
            failures += check(chat, engine, log)
            log("renamed: \(engine.allAgents().contains { $0.name == "Fuel" })")
        }

        // An agent set to a provider without a key must move instead of failing.
        if let fallback = ProviderSettings.preferred,
           let missing = Provider.allCases.first(where: { Keychain.key(for: $0) == nil }) {
            log("")
            log("=== Fallback: agent on \(missing.name) (no key) should move to \(fallback.name)")
            try? context.delete(model: ChatMessage.self)
            try? context.delete(model: Conversation.self)
            try? context.delete(model: Agent.self)
            let agent = Agent(name: "Helper", emoji: "🤖", colorHex: "#6E56CF", team: "General",
                              tagline: "Helps.", instructions: "You are a helpful assistant. Be brief.")
            agent.provider = missing.rawValue
            agent.model = "some-model"
            context.insert(agent)
            let chat = Conversation(title: "Helper", isGroup: false, memberIDs: [agent.id])
            context.insert(chat)
            let engine = AgentEngine(context: context)
            await turn(engine, chat, "Say hi in three words.")
            failures += check(chat, engine, log)
            log("moved to: \(agent.provider)/\(agent.model)")
        }

        log("")
        log(failures == 0 ? "RESULT: PASS" : "RESULT: \(failures) problem(s)")
        let url = URL.temporaryDirectory.appending(path: "selftest.txt")
        try? report.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        assumeConsent = false
    }

    @MainActor
    private static func turn(_ engine: AgentEngine, _ chat: Conversation, _ text: String) async {
        engine.send(text, in: chat)
        let start = Date()
        while engine.isBusy(chat) && Date().timeIntervalSince(start) < 240 {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    /// Logs the newest messages of a chat; counts error lines as failures.
    @MainActor
    private static func check(_ chat: Conversation, _ engine: AgentEngine, _ log: (String) -> Void,
                              label: String = "") -> Int {
        let byID = Dictionary(engine.allAgents().map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let lastUser = chat.sortedMessages.lastIndex { $0.messageKind == .user } ?? 0
        var failures = 0
        for message in chat.sortedMessages[lastUser...] {
            let who = message.agentID.flatMap { byID[$0] } ?? (message.messageKind == .user ? "You" : "-")
            let text = message.text.replacingOccurrences(of: "\n", with: " ")
            log("  \(label.isEmpty ? "" : "[\(label)] ")[\(message.kind)] \(who): \(text.prefix(160))")
            let hasConsults = chat.sortedMessages.contains { $0.parentID == message.id }
            if text.contains("⚠️") || (message.messageKind == .agent && text.isEmpty && !hasConsults) { failures += 1 }
        }
        return failures
    }
}
#endif
