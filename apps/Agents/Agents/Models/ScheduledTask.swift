import Foundation
import SwiftData

/// Something an agent does on its own at set times ("every weekday at 7:00, send my plan").
/// Syncs through iCloud like everything else; every property has a default for CloudKit.
@Model
final class ScheduledTask {
    var id: UUID = UUID()
    var title: String = ""
    /// What the agent is asked to do each time, written as an instruction to it.
    var prompt: String = ""
    var agentIDRaw: String = ""
    /// The chat the result is posted in.
    var conversationIDRaw: String = ""
    /// `ScheduleKind.rawValue`.
    var kindRaw: String = ScheduleKind.daily.rawValue
    var hour: Int = 8
    var minute: Int = 0
    /// 1 = Sunday … 7 = Saturday (Calendar's numbering), for weekly tasks.
    var weekday: Int = 2
    var intervalMinutes: Int = 60
    /// For one-off tasks.
    var onceAt: Date?
    var enabled: Bool = true
    var nextRunAt: Date = Date.distantFuture
    var lastRunAt: Date?
    /// Which device ran it last (so two devices don't both run it).
    var lastRunDevice: String = ""
    var createdAt: Date = Date()

    init(title: String, prompt: String, agentID: UUID, conversationID: UUID, kind: ScheduleKind) {
        self.id = UUID()
        self.title = title
        self.prompt = prompt
        self.agentIDRaw = agentID.uuidString
        self.conversationIDRaw = conversationID.uuidString
        self.kindRaw = kind.rawValue
        self.createdAt = Date()
    }

    var kind: ScheduleKind { ScheduleKind(rawValue: kindRaw) ?? .daily }
    var agentID: UUID? { UUID(uuidString: agentIDRaw) }
    var conversationID: UUID? { UUID(uuidString: conversationIDRaw) }

    /// The next time after `date` this task should run, or nil when a one-off task is done.
    func nextRun(after date: Date) -> Date? {
        let calendar = Calendar.current
        switch kind {
        case .once:
            guard let onceAt, onceAt > date else { return nil }
            return onceAt
        case .interval:
            return date.addingTimeInterval(Double(max(intervalMinutes, 15)) * 60)
        case .daily, .weekdays, .weekly:
            var components = DateComponents(hour: hour, minute: minute)
            if kind == .weekly { components.weekday = weekday }
            var candidate = date
            for _ in 0..<14 {
                guard let next = calendar.nextDate(after: candidate, matching: components,
                                                   matchingPolicy: .nextTime) else { return nil }
                let day = calendar.component(.weekday, from: next)
                if kind == .weekdays && (day == 1 || day == 7) {
                    candidate = next
                    continue
                }
                return next
            }
            return nil
        }
    }

    /// "Every weekday at 07:00", for chat notices and Settings.
    var scheduleDescription: String {
        let time = String(format: "%02d:%02d", hour, minute)
        switch kind {
        case .daily: return "Every day at \(time)"
        case .weekdays: return "Every weekday at \(time)"
        case .weekly:
            let name = Calendar.current.weekdaySymbols[max(0, min(6, weekday - 1))]
            return "Every \(name) at \(time)"
        case .interval:
            let minutes = max(intervalMinutes, 15)
            return minutes % 60 == 0 ? "Every \(minutes / 60) h" : "Every \(minutes) min"
        case .once:
            return "Once, \(onceAt?.formatted(date: .abbreviated, time: .shortened) ?? "")"
        }
    }
}

enum ScheduleKind: String, CaseIterable {
    case once, daily, weekdays, weekly, interval
}
