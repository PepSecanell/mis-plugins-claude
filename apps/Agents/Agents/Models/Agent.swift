import Foundation
import SwiftData

/// A specialised AI "bot". Every property has a default so the model can sync through CloudKit.
@Model
final class Agent {
    var id: UUID = UUID()
    var name: String = "New Agent"
    var emoji: String = "🤖"
    var colorHex: String = "#6E56CF"
    /// Short label shown under the name, e.g. "Health" or "YouTube".
    var team: String = "General"
    /// One-line description of what the agent is good at. Teammates see this.
    var tagline: String = ""
    /// The agent's system prompt: personality, expertise and rules.
    var instructions: String = ""
    /// `Provider.rawValue` of the AI company this agent runs on. Agents from older builds are Anthropic.
    var provider: String = Provider.anthropic.rawValue
    var model: String = ModelCatalog.defaultModel
    var effort: String = "medium"
    var webSearch: Bool = false
    var canConsult: Bool = true
    var isMain: Bool = false
    var sortOrder: Int = 0
    /// Set on the built-in agents so duplicates created on two devices can be merged.
    var seedKey: String = ""
    var createdAt: Date = Date()

    init(name: String, emoji: String, colorHex: String, team: String, tagline: String,
         instructions: String, model: String = ModelCatalog.defaultModel, effort: String = "medium",
         webSearch: Bool = false, canConsult: Bool = true, isMain: Bool = false,
         sortOrder: Int = 0, seedKey: String = "") {
        self.id = UUID()
        self.name = name
        self.emoji = emoji
        self.colorHex = colorHex
        self.team = team
        self.tagline = tagline
        self.instructions = instructions
        self.model = model
        self.effort = effort
        self.webSearch = webSearch
        self.canConsult = canConsult
        self.isMain = isMain
        self.sortOrder = sortOrder
        self.seedKey = seedKey
        self.createdAt = Date()
    }
}
