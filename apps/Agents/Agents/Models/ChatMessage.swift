import Foundation
import SwiftData

enum MessageKind: String {
    /// Something the user typed.
    case user
    /// A reply from an agent, visible in the chat.
    case agent
    /// A private agent-to-agent consultation (shown collapsed, like Grok's agent panel).
    case consult
    /// A visible hand-off note ("Don't Die handed this to Workout").
    case handoff
    /// An error or notice from the app.
    case notice
}

@Model
final class ChatMessage {
    var id: UUID = UUID()
    var kindRaw: String = MessageKind.user.rawValue
    var text: String = ""
    /// The agent that wrote this message (agent / consult answer / handoff target).
    var agentIDRaw: String = ""
    /// For consults and handoffs: the agent that asked.
    var fromAgentIDRaw: String = ""
    /// For consults: the question that was asked. For handoffs: the note.
    var question: String = ""
    /// For consults: the visible agent reply this consultation belongs to.
    var parentIDRaw: String = ""
    /// Summary of the model's reasoning, if any.
    var thinking: String = ""
    /// JSON array of {"title","url"} for web sources.
    var sourcesJSON: String = ""
    var createdAt: Date = Date()
    var conversation: Conversation?

    init(kind: MessageKind, text: String = "", agentID: UUID? = nil, fromAgentID: UUID? = nil, question: String = "") {
        self.id = UUID()
        self.kindRaw = kind.rawValue
        self.text = text
        self.agentIDRaw = agentID?.uuidString ?? ""
        self.fromAgentIDRaw = fromAgentID?.uuidString ?? ""
        self.question = question
        self.createdAt = Date()
    }

    var kind: String { kindRaw }
    var messageKind: MessageKind { MessageKind(rawValue: kindRaw) ?? .notice }
    var agentID: UUID? { UUID(uuidString: agentIDRaw) }
    var fromAgentID: UUID? { UUID(uuidString: fromAgentIDRaw) }
    var parentID: UUID? { UUID(uuidString: parentIDRaw) }

    struct Source: Codable, Hashable {
        var title: String
        var url: String
    }

    var sources: [Source] {
        get {
            guard let data = sourcesJSON.data(using: .utf8), !sourcesJSON.isEmpty else { return [] }
            return (try? JSONDecoder().decode([Source].self, from: data)) ?? []
        }
        set {
            let data = (try? JSONEncoder().encode(newValue)) ?? Data()
            sourcesJSON = String(data: data, encoding: .utf8) ?? ""
        }
    }
}
