import SwiftUI
import SwiftData
import CoreData
import CloudKit

/// Registers for the silent pushes iCloud sends when another device changes something,
/// so changes show up within seconds instead of on the next launch.
#if os(iOS)
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }
}
#else
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.registerForRemoteNotifications()
    }
}
#endif

/// Every model the app stores. New models must be added here and to the CloudKit schema.
let appModels: [any PersistentModel.Type] = [Agent.self, Conversation.self, ChatMessage.self, MemoryItem.self,
                                             ScheduledTask.self, DeviceRecord.self]

@main
struct AgentsApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #else
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    @Environment(\.scenePhase) private var scenePhase
    private let container: ModelContainer
    @State private var engine: AgentEngine
    @State private var sync: SyncCenter

    init() {
        let schema = Schema(appModels)
        let container: ModelContainer
        #if DEBUG
        if DemoContent.isEnabled || SelfTest.isEnabled {
            // Screenshot / self-test mode: throwaway in-memory store, never touches the real data or iCloud.
            container = try! ModelContainer(for: schema, configurations: ModelConfiguration(
                schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
            self.container = container
            _engine = State(initialValue: AgentEngine(context: container.mainContext))
            _sync = State(initialValue: SyncCenter(context: container.mainContext))
            return
        }
        if UserDefaults.standard.bool(forKey: "ckDiag") {
            // `-ckDiag YES`: ask CloudKit directly whether this device can reach iCloud; result to tmp/ckdiag.txt.
            Task.detached {
                var lines: [String] = []
                let container = CKContainer(identifier: "iCloud.com.keoly.agents")
                do {
                    let status = try await container.accountStatus()
                    lines.append("accountStatus: \(status.rawValue) (0 couldNotDetermine, 1 available, 2 restricted, 3 noAccount, 4 temporarilyUnavailable)")
                } catch { lines.append("accountStatus error: \(error)") }
                do {
                    let id = try await container.userRecordID()
                    lines.append("userRecordID ok: \(id.recordName.prefix(6))…")
                } catch { lines.append("userRecordID error: \(error)") }
                do {
                    _ = try await container.privateCloudDatabase.allRecordZones()
                    lines.append("private DB zones: ok")
                } catch { lines.append("private DB error: \(error)") }
                try? lines.joined(separator: "\n").write(to: URL.temporaryDirectory.appending(path: "ckdiag.txt"),
                                                          atomically: true, encoding: .utf8)
            }
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
        _sync = State(initialValue: SyncCenter(context: container.mainContext))
    }

    #if DEBUG
    private static func initializeCloudKitSchema(_ schema: Schema) {
        var report = ""
        do {
            let url = URL.temporaryDirectory.appending(path: "schema-init.store")
            let description = NSPersistentStoreDescription(url: url)
            description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
                containerIdentifier: "iCloud.com.keoly.agents")
            guard let model = NSManagedObjectModel.makeManagedObjectModel(for: appModels) else {
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
                .environment(sync)
                .task { @MainActor in
                    #if DEBUG
                    if DemoContent.isEnabled { DemoContent.load(into: container.mainContext); return }
                    if SelfTest.isEnabled {
                        await SelfTest.run(context: container.mainContext)
                        exit(0)
                    }
                    #endif
                    SeedData.prepare(container.mainContext)
                    engine.sync = sync
                    sync.start(engine: engine)
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { sync.heartbeat(); sync.runDueTasks() }
                }
        }
        .modelContainer(container)
        #if os(macOS)
        .defaultSize(width: 1100, height: 760)
        #endif
    }
}
