import Foundation

/// Chat Completions client for OpenAI and every provider with an OpenAI-compatible API
/// (Gemini, xAI, OpenRouter, Mistral, DeepSeek, Groq).
///
/// The engine builds requests and keeps history in Anthropic's shape (content blocks, tool_use,
/// tool_result). This client translates that shape to Chat Completions on the way out and turns the
/// streamed reply back into Anthropic-style blocks, so the agent loop works the same for every provider.
struct OpenAICompatClient {
    let provider: Provider
    let apiKey: String

    func stream(body: [String: Any], onEvent: @MainActor (StreamEvent) -> Void) async throws -> ClaudeResponse {
        var request = URLRequest(url: provider.baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 900
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if provider == .openrouter {
            request.setValue("Agent Teams", forHTTPHeaderField: "X-Title")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.translate(body))

        let bytes = try await openStream(request)

        var text = ""
        var toolCalls: [Int: (id: String, name: String, arguments: String)] = [:]
        var finishReason: String?
        var startedText = false

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let error = event["error"] as? [String: Any] {
                throw ClaudeError(message: error["message"] as? String ?? "\(provider.shortName) API error.")
            }
            guard let choice = (event["choices"] as? [[String: Any]])?.first else { continue }
            if let reason = choice["finish_reason"] as? String { finishReason = reason }
            guard let delta = choice["delta"] as? [String: Any] else { continue }

            let reasoning = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String) ?? ""
            if !reasoning.isEmpty { await onEvent(.thinking(reasoning)) }

            if let chunk = delta["content"] as? String, !chunk.isEmpty {
                if !startedText {
                    startedText = true
                    await onEvent(.blockStarted(type: "text", name: nil))
                }
                text += chunk
                await onEvent(.text(chunk))
            }

            for call in (delta["tool_calls"] as? [[String: Any]]) ?? [] {
                let index = call["index"] as? Int ?? toolCalls.count
                let function = call["function"] as? [String: Any] ?? [:]
                var entry = toolCalls[index] ?? (id: "", name: "", arguments: "")
                if let id = call["id"] as? String, !id.isEmpty { entry.id = id }
                if let name = function["name"] as? String, !name.isEmpty {
                    if entry.name.isEmpty { await onEvent(.blockStarted(type: "tool_use", name: name)) }
                    entry.name = name
                }
                entry.arguments += function["arguments"] as? String ?? ""
                toolCalls[index] = entry
            }
        }

        var content: [[String: Any]] = []
        if !text.isEmpty { content.append(["type": "text", "text": text]) }
        var invalid: Set<String> = []
        for index in toolCalls.keys.sorted() {
            guard let call = toolCalls[index], !call.name.isEmpty else { continue }
            let id = call.id.isEmpty ? "call_\(UUID().uuidString.prefix(12))" : call.id
            let trimmed = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            var input: [String: Any] = [:]
            if !trimmed.isEmpty {
                if let data = trimmed.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    input = parsed
                } else {
                    invalid.insert(id)
                }
            }
            content.append(["type": "tool_use", "id": id, "name": call.name, "input": input])
        }

        // Some providers report "stop" even when the reply contains tool calls.
        let stopReason: String
        if content.contains(where: { $0["type"] as? String == "tool_use" }) {
            stopReason = "tool_use"
        } else {
            switch finishReason {
            case "length": stopReason = "max_tokens"
            case "content_filter": stopReason = "refusal"
            default: stopReason = "end_turn"
            }
        }
        return ClaudeResponse(content: content, stopReason: stopReason, invalidToolUseIDs: invalid)
    }

    // MARK: - Request translation

    /// Anthropic-style request body → Chat Completions body.
    static func translate(_ body: [String: Any]) -> [String: Any] {
        var messages: [[String: Any]] = []
        if let systemBlocks = body["system"] as? [[String: Any]] {
            let system = systemBlocks.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
            if !system.isEmpty { messages.append(["role": "system", "content": system]) }
        } else if let system = body["system"] as? String, !system.isEmpty {
            messages.append(["role": "system", "content": system])
        }

        for message in body["messages"] as? [[String: Any]] ?? [] {
            let role = message["role"] as? String ?? "user"
            if let text = message["content"] as? String {
                messages.append(["role": role, "content": text])
                continue
            }
            let blocks = message["content"] as? [[String: Any]] ?? []
            if role == "assistant" {
                let text = blocks.filter { $0["type"] as? String == "text" }
                    .compactMap { $0["text"] as? String }.joined()
                let calls: [[String: Any]] = blocks.filter { $0["type"] as? String == "tool_use" }.map { block in
                    let input = block["input"] as? [String: Any] ?? [:]
                    let arguments = (try? JSONSerialization.data(withJSONObject: input))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    return [
                        "id": block["id"] as? String ?? "",
                        "type": "function",
                        "function": ["name": block["name"] as? String ?? "", "arguments": arguments],
                    ]
                }
                var out: [String: Any] = ["role": "assistant", "content": text]
                if !calls.isEmpty { out["tool_calls"] = calls }
                messages.append(out)
            } else {
                // Tool results become "tool" messages; any plain text stays a user message.
                for block in blocks where block["type"] as? String == "tool_result" {
                    let output = block["content"] as? String ?? ""
                    let isError = block["is_error"] as? Bool ?? false
                    messages.append([
                        "role": "tool",
                        "tool_call_id": block["tool_use_id"] as? String ?? "",
                        "content": isError ? "Error: \(output)" : output,
                    ])
                }
                let text = blocks.filter { $0["type"] as? String == "text" }
                    .compactMap { $0["text"] as? String }.joined(separator: "\n\n")
                if !text.isEmpty { messages.append(["role": "user", "content": text]) }
            }
        }

        var out: [String: Any] = [
            "model": body["model"] as? String ?? "",
            "messages": messages,
            "stream": true,
        ]
        // Server tools (web search) have a "type" and only exist on the Anthropic API.
        let tools: [[String: Any]] = (body["tools"] as? [[String: Any]] ?? []).compactMap { tool in
            guard tool["type"] == nil, let name = tool["name"] as? String else { return nil }
            return [
                "type": "function",
                "function": [
                    "name": name,
                    "description": tool["description"] as? String ?? "",
                    "parameters": tool["input_schema"] ?? ["type": "object", "properties": [String: Any]()],
                ],
            ]
        }
        if !tools.isEmpty { out["tools"] = tools }
        return out
    }

    // MARK: - Transport

    private func openStream(_ request: URLRequest) async throws -> URLSession.AsyncBytes {
        var attempt = 0
        while true {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ClaudeError(message: "No response from \(provider.shortName).")
            }
            if http.statusCode == 200 { return bytes }

            var data = Data()
            for try await byte in bytes { data.append(byte) }
            if (http.statusCode == 429 || http.statusCode >= 500) && attempt < 2 {
                attempt += 1
                let header = Double(http.value(forHTTPHeaderField: "retry-after") ?? "") ?? Double(attempt * 3)
                let seconds = header.isFinite ? max(0, min(header, 20)) : 3
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                continue
            }
            throw ClaudeError(message: Self.errorMessage(from: data, status: http.statusCode, provider: provider))
        }
    }

    /// Readable error from an error response. Gemini wraps errors in an array; the others don't.
    static func errorMessage(from data: Data, status: Int, provider: Provider) -> String {
        if status == 401 || status == 403 {
            return "Your \(provider.name) API key was rejected. Check it in Settings."
        }
        if status == 429 {
            return "\(provider.shortName) is rate limiting this key, or it's out of credit. Wait a moment and try again."
        }
        let json = try? JSONSerialization.jsonObject(with: data)
        let object = (json as? [String: Any]) ?? (json as? [[String: Any]])?.first
        let error = object?["error"]
        if let error = error as? [String: Any], let message = error["message"] as? String, !message.isEmpty {
            return message
        }
        if let message = error as? String, !message.isEmpty { return message }
        if let message = object?["message"] as? String, !message.isEmpty { return message }
        return "\(provider.shortName) API error (\(status))."
    }
}
