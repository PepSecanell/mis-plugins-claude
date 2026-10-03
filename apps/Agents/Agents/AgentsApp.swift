import SwiftUI
import SwiftData
import CoreData

@main
struct AgentsApp: App {
    private let container: ModelContainer
    @State private var engine: AgentEngine

    init() {
        let schema = Schema([Agent.self, Conversation.self, ChatMessage.self, MemoryItem.self])
        let container: ModelContainer
        #if DEBUG
        if DemoContent.isEnabled || SelfTest.isEnabled {
            // Screenshot / self-test mode: throwaway in-memory store, never touches the real data or iCloud.
            container = try! ModelContainer(for: schema, configurations: ModelConfiguration(
                schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
            self.container = container
            _engine = State(initialValue: AgentEngine(context: container.mainContext))
            return
        }
        if UserDefaults.standard.bool(forKey: "initCloudKitSchema") {
            // `-initCloudKitSchema YES`: push the record types to the Development environment
            // (Apple's documented route for SwiftData) and write the result to a file.
            Self.initializeCloudKitSchema(schema)
        }
        #endif
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

    #if DEBUG
    private static func initializeCloudKitSchema(_ schema: Schema) {
        var report = ""
        do {
            let url = URL.temporaryDirectory.appending(path: "schema-init.store")
            let description = NSPersistentStoreDescription(url: url)
            description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
                containerIdentifier: "iCloud.com.keoly.agents")
            guard let model = NSManagedObjectModel.makeManagedObjectModel(for: [Agent.self, Conversation.self,
                                                                               ChatMessage.self, MemoryItem.self]) else {
                throw NSError(domain: "Agents", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not build the model"])
            }
            let container = NSPersistentCloudKitContainer(name: "Agents", managedObjectModel: model)
            container.persistentStoreDescriptions = [description]
            var loadError: Error?
            container.loadPersistentStores { _, error in loadError = error }
            if let loadError { throw loadError }
            try container.initializeCloudKitSchema()
            report = "OK: schema initialized"
            if let store = container.persistentStoreCoordinator.persistentStores.first {
                try container.persistentStoreCoordinator.remove(store)
            }
        } catch {
            report = "FAILED: \(error)"
        }
        try? report.write(to: URL.temporaryDirectory.appending(path: "schema-init.txt"), atomically: true, encoding: .utf8)
        print("[schema-init] \(report)")
    }
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(engine)
                .task { @MainActor in
                    #if DEBUG
                    if DemoContent.isEnabled { DemoContent.load(into: container.mainContext); return }
                    if SelfTest.isEnabled {
                        await SelfTest.run(context: container.mainContext)
                        exit(0)
                    }
                    #endif
                    SeedData.prepare(container.mainContext)
                }
        }
        .modelContainer(container)
        #if os(macOS)
        .defaultSize(width: 1100, height: 760)
        #endif
    }
}
