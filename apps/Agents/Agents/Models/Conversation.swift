import Foundation
import SwiftData

@Model
final class Conversation {
    var id: UUID = UUID()
    var title: String = ""
    var isGroup: Bool = false
    /// Comma-separated agent UUIDs (kept as a string so it syncs cleanly through CloudKit).
    var memberIDsRaw: String = ""
    var pinned: Bool = false
    /// Set on the built-in group chat so duplicates from two devices can be merged.
    var seedKey: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.conversation)
    var messages: [ChatMessage]? = []

    init(title: String, isGroup: Bool, memberIDs: [UUID]) {
        self.id = UUID()
        self.title = title
        self.isGroup = isGroup
        self.memberIDsRaw = memberIDs.map(\.uuidString).joined(separator: ",")
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    var memberIDs: [UUID] {
        get { memberIDsRaw.split(separator: ",").compactMap { UUID(uuidString: String($0)) } }
        set { memberIDsRaw = newValue.map(\.uuidString).joined(separator: ",") }
    }

    var sortedMessages: [ChatMessage] {
        (messages ?? []).sorted { $0.createdAt < $1.createdAt }
    }

    var lastMessage: ChatMessage? {
        (messages ?? []).filter { $0.kind != MessageKind.consult.rawValue }.max { $0.createdAt < $1.createdAt }
    }
}
