import SwiftUI
import SwiftData

/// One line under the chats list: which other devices are connected and when iCloud last synced.
struct SyncStatusLine: View {
    @Environment(SyncCenter.self) private var sync
    @Query(sort: \DeviceRecord.lastSeen, order: .reverse) private var devices: [DeviceRecord]

    private var others: [DeviceRecord] {
        devices.filter { $0.deviceID != sync.deviceID && Date().timeIntervalSince($0.lastSeen) < 30 * 86_400 }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { _ in
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(color)
                Text(text).lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var icon: String {
        if sync.lastError != nil { return "exclamationmark.icloud" }
        if sync.syncing { return "arrow.triangle.2.circlepath.icloud" }
        return others.isEmpty ? "icloud" : "checkmark.icloud"
    }

    private var color: Color {
        if sync.lastError != nil { return .orange }
        return others.contains(where: \.isActive) ? .green : .secondary
    }

    private var text: String {
        if sync.lastError != nil { return "iCloud sync paused. Check iCloud in Settings." }
        guard !others.isEmpty else {
            return "Synced with iCloud. Open Agent Teams on your other devices to connect them."
        }
        let names = others.map(\.name).joined(separator: ", ")
        if let last = sync.lastSync {
            return "In sync with \(names) · \(last.formatted(.relative(presentation: .named)))"
        }
        return "Connected to \(names)"
    }
}

/// Settings section: every device with the app, and the state of iCloud sync.
struct DevicesSection: View {
    @Environment(SyncCenter.self) private var sync
    @Query(sort: \DeviceRecord.lastSeen, order: .reverse) private var devices: [DeviceRecord]

    var body: some View {
        Section {
            TimelineView(.periodic(from: .now, by: 10)) { _ in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(devices.filter { Date().timeIntervalSince($0.lastSeen) < 30 * 86_400 }) { device in
                        HStack(spacing: 12) {
                            Image(systemName: device.isMac ? "laptopcomputer" : (device.platform == "ipad" ? "ipad" : "iphone"))
                                .font(.title3)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.deviceID == sync.deviceID ? "\(device.name) (this device)" : device.name)
                                Text(status(of: device)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Circle()
                                .fill(device.isActive || device.deviceID == sync.deviceID ? Color.green : Color.secondary.opacity(0.4))
                                .frame(width: 8, height: 8)
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
        } header: {
            Text("Your devices")
        } footer: {
            Text(footer)
        }
    }

    private func status(of device: DeviceRecord) -> String {
        if device.deviceID == sync.deviceID { return "Open now" }
        if device.isActive { return "Open now · changes arrive in a few seconds" }
        return "Last open \(device.lastSeen.formatted(.relative(presentation: .named)))"
    }

    private var footer: String {
        var text = "Everything syncs through your own iCloud. Messages usually appear on your other devices within a few seconds."
        if let last = sync.lastSync {
            text += " Last sync \(last.formatted(.relative(presentation: .named)))."
        }
        if let error = sync.lastError { text += " iCloud: \(error)" }
        return text
    }
}

/// Settings › Scheduled tasks: everything the agents do on their own, with pause and delete.
struct ScheduledTasksView: View {
    @Environment(\.modelContext) private var context
    @Environment(SyncCenter.self) private var sync
    @Query(sort: \ScheduledTask.createdAt) private var tasks: [ScheduledTask]
    @Query private var agents: [Agent]

    var body: some View {
        Form {
            if tasks.isEmpty {
                Section {
                    Text("No scheduled tasks yet. Ask any agent, for example: \"Every weekday at 7:30, send me a plan for the day.\"")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(tasks) { task in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("⏰ \(task.title)").font(.headline)
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { task.enabled },
                                set: { value in
                                    task.enabled = value
                                    if value { sync.reschedule(task) } else { try? context.save(); sync.refreshNotifications() }
                                }))
                            .labelsHidden()
                        }
                        Text("\(agentName(task)) · \(task.scheduleDescription)").font(.subheadline).foregroundStyle(.secondary)
                        Text(task.enabled && task.nextRunAt < .distantFuture
                             ? "Next: \(task.nextRunAt.formatted(date: .abbreviated, time: .shortened))"
                             : "Paused")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(task.prompt).font(.caption).foregroundStyle(.tertiary).lineLimit(3)
                    }
                    .padding(.vertical, 4)
                    .contextMenu {
                        Button("Delete", systemImage: "trash", role: .destructive) { delete(task) }
                    }
                }
                .onDelete { offsets in offsets.map { tasks[$0] }.forEach(delete) }
            } footer: {
                if !tasks.isEmpty {
                    Text("Tasks run on your Mac on time while Agent Teams is open there. On iPhone and iPad you get a notification, and the task runs when you open the app if your Mac didn't already do it.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Scheduled Tasks")
    }

    private func agentName(_ task: ScheduledTask) -> String {
        agents.first { $0.id == task.agentID }?.name ?? "Agent"
    }

    private func delete(_ task: ScheduledTask) {
        context.delete(task)
        try? context.save()
        sync.refreshNotifications()
    }
}
