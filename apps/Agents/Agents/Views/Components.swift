import SwiftUI

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

enum Palette {
    static let colors = ["#12A594", "#E5484D", "#F76B15", "#FFC53D", "#46A758", "#3E63DD", "#6E56CF", "#E54666", "#0090FF", "#8D8D8D"]
}

struct AgentAvatar: View {
    let emoji: String
    let colorHex: String
    var size: CGFloat = 36

    init(agent: Agent?, size: CGFloat = 36) {
        self.emoji = agent?.emoji ?? "🤖"
        self.colorHex = agent?.colorHex ?? "#8D8D8D"
        self.size = size
    }

    init(emoji: String, colorHex: String, size: CGFloat = 36) {
        self.emoji = emoji
        self.colorHex = colorHex
        self.size = size
    }

    var body: some View {
        Text(emoji.isEmpty ? "🤖" : emoji)
            .font(.system(size: size * 0.52))
            .frame(width: size, height: size)
            .background(Circle().fill(Color(hex: colorHex).opacity(0.2)))
            .overlay(Circle().strokeBorder(Color(hex: colorHex).opacity(0.5), lineWidth: 1))
    }
}

/// Overlapping avatars for a group chat.
struct GroupAvatar: View {
    let agents: [Agent]
    var size: CGFloat = 44

    var body: some View {
        let shown = Array(agents.prefix(3))
        Group {
            if shown.count <= 1 {
                AgentAvatar(agent: shown.first, size: size)
            } else {
                HStack(spacing: -size * 0.32) {
                    ForEach(shown, id: \.id) { agent in
                        AgentAvatar(agent: agent, size: size * 0.6)
                            .background(Circle().fill(.background))
                    }
                }
            }
        }
        .frame(width: size, height: size)
    }
}

/// Renders the Markdown agents write: headings, bullet and numbered lists, and inline styling.
struct MarkdownText: View {
    let text: String

    private enum Block: Hashable {
        case heading(String)
        case bullet(String, indent: Int)
        case numbered(String, String)
        case paragraph(String)
        case rule
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let value):
                    inline(value).font(.headline).padding(.top, 4)
                case .bullet(let value, let indent):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        inline(value)
                    }
                    .padding(.leading, CGFloat(indent) * 14)
                case .numbered(let number, let value):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(number).monospacedDigit()
                        inline(value)
                    }
                case .paragraph(let value):
                    inline(value)
                case .rule:
                    Divider()
                }
            }
        }
        .textSelection(.enabled)
    }

    private func inline(_ value: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: value, options: options) {
            return Text(attributed)
        }
        return Text(value)
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty {
                result.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph.removeAll()
            }
        }
        for rawLine in text.components(separatedBy: "\n") {
            let leading = rawLine.prefix { $0 == " " }.count
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line == "---" || line == "***" { flush(); result.append(.rule); continue }
            if line.hasPrefix("#") {
                flush()
                result.append(.heading(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flush()
                result.append(.bullet(String(line.dropFirst(2)), indent: leading / 2))
            } else if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
                      line[line.index(after: dot)...].hasPrefix(" ") {
                flush()
                result.append(.numbered(String(line[...dot]), String(line[line.index(dot, offsetBy: 2)...])))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return result
    }
}

/// Three pulsing dots shown while an agent is working.
struct TypingIndicator: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .frame(width: 6, height: 6)
                        .opacity(0.3 + 0.7 * (0.5 + 0.5 * sin(t * 5 - Double(index) * 0.8)))
                }
            }
        }
        .foregroundStyle(.secondary)
    }
}
