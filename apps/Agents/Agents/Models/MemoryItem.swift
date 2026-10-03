import Foundation
import SwiftData

/// A fact about the user that every agent can read ("About me" memory).
@Model
final class MemoryItem {
    var id: UUID = UUID()
    var text: String = ""
    var sourceAgentName: String = ""
    var createdAt: Date = Date()

    init(text: String, sourceAgentName: String) {
        self.id = UUID()
        self.text = text
        self.sourceAgentName = sourceAgentName
        self.createdAt = Date()
    }

    /// Short id the agents use to refer to a memory (first 6 hex chars).
    var shortID: String { String(id.uuidString.prefix(6)).lowercased() }
}
