import Foundation
import SwiftData

/// Tools that let any agent set up work it does on its own at set times.
enum ScheduleTools {
    static let names: Set<String> = ["create_scheduled_task", "list_scheduled_tasks",
                                     "update_scheduled_task", "delete_scheduled_task"]

    private static let scheduleFields: [String: Any] = [
        "schedule": ["type": "string", "enum": ScheduleKind.allCases.map(\.rawValue),
                     "description": "once, daily, weekdays (Mon-Fri), weekly, or interval."],
        "time": ["type": "string", "description": "24h local time HH:MM for daily, weekdays and weekly, e.g. 07:30."],
        "weekday": ["type": "string", "description": "For weekly: monday, tuesday, … sunday."],
        "interval_minutes": ["type": "integer", "description": "For interval: minutes between runs, at least 15."],
        "date": ["type": "string", "description": "For once: local date and time, YYYY-MM-DD HH:MM."],
    ]

    static var definitions: [[String: Any]] {
        var create = scheduleFields
        create["title"] = ["type": "string", "description": "Short name, e.g. Morning plan."]
        create["prompt"] = ["type": "string", "description": "What the agent should do each time, written as an instruction to it, with the context it needs (it won't remember why it was set up)."]
        create["agent_name"] = ["type": "string", "description": "Which agent does it. Defaults to you."]
        create["post_in"] = ["type": "string", "enum": ["this_chat", "agent_chat"],
                             "description": "Post results in this chat (default) or in the agent's own 1-on-1 chat."]
        var update = scheduleFields
        update["title"] = ["type": "string", "description": "Current title of the task to change."]
        update["new_title"] = ["type": "string"]
        update["prompt"] = ["type": "string"]
        update["enabled"] = ["type": "boolean", "description": "Pause (false) or resume (true)."]

        return [
            [
                "name": "create_scheduled_task",
                "description": "Schedule something an agent will do on its own, once or repeatedly (a morning plan, a weekly review, a reminder). Confirm the time with the user when it isn't clear. Tell the user what you scheduled.",
                "input_schema": ["type": "object", "properties": create, "required": ["title", "prompt", "schedule"]],
            ],
            [
                "name": "list_scheduled_tasks",
                "description": "List the user's scheduled tasks with their next run times.",
                "input_schema": ["type": "object", "properties": [String: Any]()],
            ],
            [
                "name": "update_scheduled_task",
                "description": "Change, pause or resume a scheduled task. Fields you pass are replaced.",
                "input_schema": ["type": "object", "properties": update, "required": ["title"]],
            ],
            [
                "name": "delete_scheduled_task",
                "description": "Delete a scheduled task, after the user asked for it.",
                "input_schema": [
                    "type": "object",
                    "properties": ["title": ["type": "string", "description": "Title of the task to delete."]],
                    "required": ["title"],
                ],
            ],
        ]
    }
}

extension AgentEngine {
    func runScheduleTool(_ name: String, input: [String: Any], agent: Agent,
                         conversation: Conversation) -> (text: String, isError: Bool)? {
        guard ScheduleTools.names.contains(name) else { return nil }
        switch name {
        case "create_scheduled_task": return createTask(input, agent: agent, conversation: conversation)
        case "list_scheduled_tasks": return (listTasks(), false)
        case "update_scheduled_task": return updateTask(input, conversation: conversation)
        default: return deleteTask(input, conversation: conversation)
        }
    }

    func allTasks() -> [ScheduledTask] {
        (try? context.fetch(FetchDescriptor<ScheduledTask>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    /// The chat a task posts in: the one it was set up for, else the agent's 1-on-1 chat (created if needed).
    func conversation(for task: ScheduledTask, agent: Agent) -> Conversation {
        let conversations = (try? context.fetch(FetchDescriptor<Conversation>())) ?? []
        if let id = task.conversationID, let chat = conversations.first(where: { $0.id == id }) { return chat }
        return directChat(with: agent, among: conversations)
    }

    private func directChat(with agent: Agent, among conversations: [Conversation]) -> Conversation {
        if let chat = conversations.first(where: { !$0.isGroup && $0.memberIDs == [agent.id] }) { return chat }
        let chat = Conversation(title: agent.name, isGroup: false, memberIDs: [agent.id])
        context.insert(chat)
        return chat
    }

    // MARK: - Tools

    private func createTask(_ input: [String: Any], agent: Agent, conversation: Conversation) -> (String, Bool) {
        guard let title = Self.text(input["title"]) else { return ("title is required.", true) }
        guard let prompt = Self.text(input["prompt"]) else { return ("prompt is required.", true) }
        var owner = agent
        if let wanted = Self.text(input["agent_name"]) {
            guard let match = Self.match(wanted, in: allAgents()) else {
                return ("No agent called \"\(wanted)\". Agents: \(allAgents().map(\.name).joined(separator: ", ")).", true)
            }
            owner = match
        }
        let target = Self.text(input["post_in"]) == "agent_chat"
            ? directChat(with: owner, among: (try? context.fetch(FetchDescriptor<Conversation>())) ?? [])
            : conversation
        let task = ScheduledTask(title: title, prompt: prompt, agentID: owner.id, conversationID: target.id, kind: .daily)
        if let error = applySchedule(input, to: task, requireKind: true) { return (error, true) }
        task.nextRunAt = task.nextRun(after: Date()) ?? .distantFuture
        if task.nextRunAt == .distantFuture { return ("That time is already in the past. Pick a future time.", true) }
        context.insert(task)
        append(ChatMessage(kind: .notice, text: "Scheduled ⏰ \(title) · \(task.scheduleDescription) · \(owner.name)"),
               to: conversation)
        save()
        sync?.refreshNotifications()
        return ("Scheduled \"\(title)\" for \(owner.name): \(task.scheduleDescription). Next run \(Self.when(task.nextRunAt)).", false)
    }

    private func listTasks() -> String {
        let tasks = allTasks()
        if tasks.isEmpty { return "No scheduled tasks." }
        let names = Dictionary(allAgents().map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        return tasks.map { task in
            let owner = task.agentID.flatMap { names[$0] } ?? "?"
            let next = task.enabled ? "next \(Self.when(task.nextRunAt))" : "paused"
            return "- \(task.title) [\(owner)] \(task.scheduleDescription), \(next)\n  prompt: \(task.prompt)"
        }.joined(separator: "\n")
    }

    private func updateTask(_ input: [String: Any], conversation: Conversation) -> (String, Bool) {
        guard let title = Self.text(input["title"]), let task = findTask(title) else {
            return ("No scheduled task with that title. Tasks: \(allTasks().map(\.title).joined(separator: ", ")).", true)
        }
        if let newTitle = Self.text(input["new_title"]) { task.title = newTitle }
        if let prompt = Self.text(input["prompt"]) { task.prompt = prompt }
        if let error = applySchedule(input, to: task, requireKind: false) { return (error, true) }
        if let enabled = input["enabled"] as? Bool { task.enabled = enabled }
        task.nextRunAt = task.nextRun(after: Date()) ?? .distantFuture
        append(ChatMessage(kind: .notice, text: "Updated ⏰ \(task.title) · \(task.enabled ? task.scheduleDescription : "paused")"),
               to: conversation)
        save()
        sync?.refreshNotifications()
        return ("Updated \"\(task.title)\": \(task.enabled ? task.scheduleDescription : "paused").", false)
    }

    private func deleteTask(_ input: [String: Any], conversation: Conversation) -> (String, Bool) {
        guard let title = Self.text(input["title"]), let task = findTask(title) else {
            return ("No scheduled task with that title.", true)
        }
        let name = task.title
        context.delete(task)
        append(ChatMessage(kind: .notice, text: "Deleted ⏰ \(name)"), to: conversation)
        save()
        sync?.refreshNotifications()
        return ("Deleted \"\(name)\".", false)
    }

    // MARK: - Helpers

    private func findTask(_ title: String) -> ScheduledTask? {
        let wanted = Mentions.normalize(title)
        return allTasks().first { Mentions.normalize($0.title) == wanted }
            ?? allTasks().first { Mentions.normalize($0.title).contains(wanted) }
    }

    /// Reads schedule fields into the task. Returns an error message when something can't be understood.
    private func applySchedule(_ input: [String: Any], to task: ScheduledTask, requireKind: Bool) -> String? {
        if let raw = Self.text(input["schedule"]) {
            guard let kind = ScheduleKind(rawValue: raw.lowercased()) else {
                return "schedule must be one of \(ScheduleKind.allCases.map(\.rawValue).joined(separator: ", "))."
            }
            task.kindRaw = kind.rawValue
        } else if requireKind {
            return "schedule is required."
        }
        if let time = Self.text(input["time"]) {
            let parts = time.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else {
                return "time must be HH:MM, e.g. 07:30."
            }
            task.hour = parts[0]
            task.minute = parts[1]
        } else if requireKind && [.daily, .weekdays, .weekly].contains(task.kind) {
            return "time is required for \(task.kind.rawValue) tasks."
        }
        if let day = Self.text(input["weekday"])?.lowercased() {
            let names = Calendar(identifier: .gregorian).weekdaySymbols.map { $0.lowercased() }
            let english = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
            guard let index = english.firstIndex(of: day) ?? names.firstIndex(of: day) else {
                return "weekday must be monday … sunday."
            }
            task.weekday = index + 1
        }
        if let minutes = input["interval_minutes"] as? Int { task.intervalMinutes = max(minutes, 15) }
        if let date = Self.text(input["date"]) {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            formatter.timeZone = .current
            guard let parsed = formatter.date(from: date) else { return "date must be YYYY-MM-DD HH:MM." }
            task.onceAt = parsed
        } else if requireKind && task.kind == .once {
            return "date is required for once tasks."
        }
        return nil
    }

    private static func when(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private static func text(_ value: Any?) -> String? {
        let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }
}
