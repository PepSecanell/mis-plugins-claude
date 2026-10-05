import Foundation
import SwiftData
import CoreData
import Observation
import UserNotifications
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Everything about this device being connected to the user's other devices:
/// iCloud sync status, the device list, cleaning up after imports, and running scheduled tasks.
@MainActor
@Observable
final class SyncCenter {
    /// Last time iCloud finished sending or receiving changes.
    private(set) var lastSync: Date?
    private(set) var syncing = false
    private(set) var lastError: String?

    let deviceID: String
    private let context: ModelContext
    @ObservationIgnored private weak var engine: AgentEngine?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observer: NSObjectProtocol?
    #if os(macOS)
    @ObservationIgnored private var activity: NSObjectProtocol?
    #endif

    init(context: ModelContext) {
        self.context = context
        if let saved = UserDefaults.standard.string(forKey: "device.id") {
            deviceID = saved
        } else {
            deviceID = UUID().uuidString
            UserDefaults.standard.set(deviceID, forKey: "device.id")
        }
    }

    func start(engine: AgentEngine) {
        self.engine = engine
        // SwiftData syncs through NSPersistentCloudKitContainer, which reports every import/export.
        observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else { return }
            MainActor.assumeIsolated { self?.handle(event) }
        }
        heartbeat()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
        #if os(macOS)
        // Keep timers on time while the window is hidden, so scheduled tasks run when they should.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                         reason: "Running scheduled agent tasks")
        #endif
    }

    // MARK: - iCloud events

    private func handle(_ event: NSPersistentCloudKitContainer.Event) {
        if event.endDate == nil {
            syncing = true
            return
        }
        syncing = false
        if event.succeeded {
            lastSync = event.endDate
            lastError = nil
            if event.type == .import {
                // The other device's starter agents/chats may have just arrived: merge duplicates.
                SeedData.mergeDuplicates(context)
                try? context.save()
                Task { await ProviderRouting.repairAll(in: context) }
                refreshNotifications()
            }
        } else if let error = event.error {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Devices

    static var deviceName: String {
        #if os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }

    static var platform: String {
        #if os(macOS)
        return "mac"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        #endif
    }

    /// Marks this device as active. Runs on launch, every minute while open and when coming to the front.
    func heartbeat() {
        let id = deviceID
        let records = (try? context.fetch(FetchDescriptor<DeviceRecord>(predicate: #Predicate { $0.deviceID == id }))) ?? []
        let mine = records.first ?? {
            let record = DeviceRecord(deviceID: id, name: Self.deviceName, platform: Self.platform)
            context.insert(record)
            return record
        }()
        for extra in records.dropFirst() { context.delete(extra) }
        mine.name = Self.deviceName
        mine.lastSeen = Date()
        try? context.save()
    }

    func devices() -> [DeviceRecord] {
        let all = (try? context.fetch(FetchDescriptor<DeviceRecord>(sortBy: [SortDescriptor(\.lastSeen, order: .reverse)]))) ?? []
        // Hide devices not seen for 30 days (old installs).
        return all.filter { Date().timeIntervalSince($0.lastSeen) < 30 * 86_400 }
    }

    // MARK: - Scheduled tasks

    private var tickCount = 0

    private func tick() {
        tickCount += 1
        if tickCount % 3 == 1 { heartbeat() }
        runDueTasks()
    }

    /// A Mac runs tasks on time. An iPhone or iPad runs a task only when no Mac has been active recently,
    /// or when the task is more than five minutes overdue (the Mac is asleep or closed).
    private func shouldRun(_ task: ScheduledTask, now: Date) -> Bool {
        if Self.platform == "mac" { return true }
        let macActive = devices().contains { $0.isMac && $0.isActive && $0.deviceID != deviceID }
        return !macActive || now.timeIntervalSince(task.nextRunAt) > 300
    }

    func runDueTasks() {
        guard let engine else { return }
        let now = Date()
        let due = ((try? context.fetch(FetchDescriptor<ScheduledTask>())) ?? [])
            .filter { $0.enabled && $0.nextRunAt <= now }
        for task in due where shouldRun(task, now: now) {
            guard let agent = engine.allAgents().first(where: { $0.id == task.agentID }) else {
                task.enabled = false
                continue
            }
            let conversation = engine.conversation(for: task, agent: agent)
            guard !engine.isBusy(conversation) else { continue } // try again on the next tick
            // Claim it before running so another device that syncs this sees it's done.
            task.lastRunAt = now
            task.lastRunDevice = deviceID
            if let next = task.nextRun(after: now) {
                task.nextRunAt = next
            } else {
                task.enabled = false
                task.nextRunAt = .distantFuture
            }
            try? context.save()
            engine.send("⏰ \(task.title)\n\n\(task.prompt)", in: conversation)
            notifyRan(task, agent: agent)
        }
        refreshNotifications()
    }

    /// Recomputes when a task should next run (after it's created or edited).
    func reschedule(_ task: ScheduledTask) {
        task.nextRunAt = task.nextRun(after: Date()) ?? .distantFuture
        if task.nextRunAt == .distantFuture && task.kind == .once { task.enabled = false }
        try? context.save()
        refreshNotifications()
    }

    // MARK: - Notifications

    /// iPhone and iPad: a reminder at each task's next run, so the user knows when there's something to read
    /// even if the Mac ran it. Requests permission the first time there's a task.
    func refreshNotifications() {
        let tasks = ((try? context.fetch(FetchDescriptor<ScheduledTask>())) ?? []).filter(\.enabled)
        let agents = engine?.allAgents() ?? []
        let center = UNUserNotificationCenter.current()
        Task {
            if !tasks.isEmpty {
                let settings = await center.notificationSettings()
                if settings.authorizationStatus == .notDetermined {
                    _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
                }
            }
            center.removeAllPendingNotificationRequests()
            #if os(iOS)
            for task in tasks where task.nextRunAt < .distantFuture {
                let name = agents.first { $0.id == task.agentID }?.name ?? "Your agent"
                let content = UNMutableNotificationContent()
                content.title = "⏰ \(task.title)"
                content.body = "\(name) is on it. Open Agent Teams to see the reply."
                content.sound = .default
                let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: task.nextRunAt)
                let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
                try? await center.add(UNNotificationRequest(identifier: task.id.uuidString, content: content, trigger: trigger))
            }
            #endif
        }
    }

    /// Mac: a notification when a scheduled task has run, in case the window isn't in front.
    private func notifyRan(_ task: ScheduledTask, agent: Agent) {
        #if os(macOS)
        let content = UNMutableNotificationContent()
        content.title = "⏰ \(task.title)"
        content.body = "\(agent.name) is working on it in Agent Teams."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        #endif
    }
}
