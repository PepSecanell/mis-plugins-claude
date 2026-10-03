import SwiftUI
import SwiftData

@main
struct AgentsApp: App {
    private let container: ModelContainer
    @State private var engine: AgentEngine

    init() {
        let schema = Schema([Agent.self, Conversation.self, ChatMessage.self, MemoryItem.self])
        let container: ModelContainer
        do {
            // Syncs agents, chats and memory through your private iCloud database.
            container = try ModelContainer(for: schema,
                                           configurations: ModelConfiguration(schema: schema, cloudKitDatabase: .automatic))
        } catch {
            // iCloud isn't set up for this build yet: keep everything on this device.
            container = try! ModelContainer(for: schema,
                                            configurations: ModelConfiguration(schema: schema, cloudKitDatabase: .none))
        }
        self.container = container
        _engine = State(initialValue: AgentEngine(context: container.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(engine)
                .task { @MainActor in SeedData.prepare(container.mainContext) }
        }
        .modelContainer(container)
        #if os(macOS)
        .defaultSize(width: 1100, height: 760)
        #endif
    }
}
