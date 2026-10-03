import Foundation

enum ModelCatalog {
    static let defaultModel = "claude-opus-5-5"

    struct Option: Identifiable, Hashable {
        let id: String
        let label: String
        let detail: String
    }

    static let options: [Option] = [
        Option(id: "claude-opus-5-5", label: "Opus 5.5", detail: "Smartest · $4 / $20 per million tokens"),
        Option(id: "claude-sonnet-5-5", label: "Sonnet 5.5", detail: "Fast, half the price · $2 / $10"),
        Option(id: "claude-haiku-4-5", label: "Haiku 4.5", detail: "Fastest & cheapest · $1 / $5"),
    ]

    static let efforts = ["low", "medium", "high", "xhigh", "max"]

    static func label(for model: String) -> String {
        options.first { $0.id == model }?.label ?? model
    }

    /// Haiku 4.5 does not take adaptive thinking or `effort`.
    static func supportsAdaptiveThinking(_ model: String) -> Bool {
        !model.hasPrefix("claude-haiku")
    }

    static func webSearchToolType(_ model: String) -> String {
        model.hasPrefix("claude-haiku") ? "web_search_20250305" : "web_search_20260209"
    }

    /// Models that accept the server-side `fallbacks: "default"` parameter on the Claude API.
    static func supportsFallbacks(_ model: String) -> Bool {
        ["claude-opus-5-5", "claude-sonnet-5-5", "claude-opus-5", "claude-fable-5-1"].contains(model)
    }

    /// Cheap model used for small housekeeping calls (routing group chats, titles).
    static let utilityModel = "claude-haiku-4-5"
}
