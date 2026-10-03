import Foundation

struct ClaudeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Events surfaced to the UI while a response streams in.
enum StreamEvent {
    case text(String)
    case thinking(String)
    case blockStarted(type: String, name: String?)
}

struct ClaudeResponse {
    /// Every content block exactly as the API sent it (tool loops echo these back unchanged).
    var content: [[String: Any]]
    var stopReason: String?
    /// ids of tool_use blocks whose streamed input could not be parsed.
    var invalidToolUseIDs: Set<String>
}

/// Minimal Messages API client over raw HTTP + Server-Sent Events.
/// There is no official Anthropic SDK for Swift, so this talks to the REST API directly.
struct ClaudeClient {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    let apiKey: String

    func stream(body: [String: Any], betas: [String] = [],
                onEvent: @MainActor (StreamEvent) -> Void) async throws -> ClaudeResponse {
        var body = body
        body["stream"] = true
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 900
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if !betas.isEmpty {
            request.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let bytes = try await openStream(request)

        var blocks: [Int: [String: Any]] = [:]
        var partialJSON: [Int: String] = [:]
        var invalid: Set<String> = []
        var stopReason: String?

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String else { continue }

            switch type {
            case "content_block_start":
                guard let index = event["index"] as? Int,
                      let block = event["content_block"] as? [String: Any] else { continue }
                blocks[index] = block
                let blockType = block["type"] as? String ?? ""
                await onEvent(.blockStarted(type: blockType, name: block["name"] as? String))
                if blockType == "text", let text = block["text"] as? String, !text.isEmpty {
                    await onEvent(.text(text))
                }

            case "content_block_delta":
                guard let index = event["index"] as? Int, var block = blocks[index],
                      let delta = event["delta"] as? [String: Any],
                      let deltaType = delta["type"] as? String else { continue }
                switch deltaType {
                case "text_delta":
                    let text = delta["text"] as? String ?? ""
                    block["text"] = (block["text"] as? String ?? "") + text
                    await onEvent(.text(text))
                case "input_json_delta":
                    partialJSON[index, default: ""] += delta["partial_json"] as? String ?? ""
                case "thinking_delta":
                    let text = delta["thinking"] as? String ?? ""
                    block["thinking"] = (block["thinking"] as? String ?? "") + text
                    await onEvent(.thinking(text))
                case "signature_delta":
                    block["signature"] = (block["signature"] as? String ?? "") + (delta["signature"] as? String ?? "")
                case "citations_delta":
                    if let citation = delta["citation"] {
                        var list = block["citations"] as? [Any] ?? []
                        list.append(citation)
                        block["citations"] = list
                    }
                default:
                    break
                }
                blocks[index] = block

            case "content_block_stop":
                guard let index = event["index"] as? Int, var block = blocks[index] else { continue }
                if let raw = partialJSON[index] {
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        block["input"] = [String: Any]()
                    } else if let data = trimmed.data(using: .utf8),
                              let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        block["input"] = input
                    } else {
                        block["input"] = [String: Any]()
                        if let id = block["id"] as? String { invalid.insert(id) }
                    }
                }
                blocks[index] = block

            case "message_delta":
                if let delta = event["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String {
                    stopReason = reason
                }

            case "error":
                let err = event["error"] as? [String: Any]
                throw ClaudeError(message: Self.friendly(type: err?["type"] as? String,
                                                         message: err?["message"] as? String, status: nil))
            default:
                break // message_start, ping, message_stop
            }
        }

        let content = blocks.keys.sorted().compactMap { blocks[$0] }.map(Self.removingNulls)
        return ClaudeResponse(content: content, stopReason: stopReason, invalidToolUseIDs: invalid)
    }

    /// Opens the SSE stream, retrying rate-limit / overload / server errors a couple of times.
    private func openStream(_ request: URLRequest) async throws -> URLSession.AsyncBytes {
        var attempt = 0
        while true {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ClaudeError(message: "No response from the Claude API.")
            }
            if http.statusCode == 200 { return bytes }

            var data = Data()
            for try await byte in bytes { data.append(byte) }
            let retryable = http.statusCode == 429 || http.statusCode >= 500
            if retryable && attempt < 2 {
                attempt += 1
                let header = Double(http.value(forHTTPHeaderField: "retry-after") ?? "") ?? Double(attempt * 3)
                let seconds = header.isFinite ? max(0, min(header, 20)) : 3
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                continue
            }
            let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
            throw ClaudeError(message: Self.friendly(type: json?["type"] as? String,
                                                     message: json?["message"] as? String,
                                                     status: http.statusCode))
        }
    }

    private static func friendly(type: String?, message: String?, status: Int?) -> String {
        let type = type ?? ""
        let status = status ?? 0
        if type == "authentication_error" || status == 401 {
            return "Your Anthropic API key was rejected. Check it in Settings."
        }
        if type == "permission_error" || status == 403 {
            return "This API key isn't allowed to do that. \(message ?? "")"
        }
        if type == "rate_limit_error" || status == 429 {
            return "Rate limited by the Claude API. Wait a moment and try again."
        }
        if type == "overloaded_error" || status == 529 {
            return "Claude is overloaded right now. Try again in a minute."
        }
        if let message, !message.isEmpty { return message }
        return status > 0 ? "Claude API error (\(status))." : "Claude API error."
    }

    /// JSONSerialization turns `null` into NSNull; strip those so echoed blocks stay valid.
    static func removingNulls(_ dict: [String: Any]) -> [String: Any] {
        dict.filter { !($0.value is NSNull) }
    }

    /// Joins the text blocks of a response.
    static func text(of content: [[String: Any]]) -> String {
        content.filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
    }
}
