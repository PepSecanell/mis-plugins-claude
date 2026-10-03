import Foundation

/// OpenAI's Responses API. Newer OpenAI models (GPT-6 and later) only support tools here, not on
/// Chat Completions. Like OpenAICompatClient it takes the engine's Anthropic-shaped request and returns
/// Anthropic-shaped blocks; each block also keeps the raw OpenAI output item under `openai_item` so the
/// next request in a tool loop can send every item back verbatim (reasoning included), as OpenAI asks
/// when `store` is false.
struct OpenAIResponsesClient {
    let apiKey: String

    static let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    func stream(body: [String: Any], onEvent: @MainActor (StreamEvent) -> Void) async throws -> ClaudeResponse {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 900
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: Self.translate(body))

        let bytes = try await OpenAICompatClient(provider: .openai, apiKey: apiKey).openStream(request)

        var items: [Int: [String: Any]] = [:]
        var status = "completed"
        var incompleteReason: String?
        var startedText = false

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String else { continue }

            switch type {
            case "response.output_item.added":
                if let item = event["item"] as? [String: Any], item["type"] as? String == "function_call" {
                    await onEvent(.blockStarted(type: "tool_use", name: item["name"] as? String))
                }
            case "response.output_text.delta":
                let chunk = event["delta"] as? String ?? ""
                if !startedText {
                    startedText = true
                    await onEvent(.blockStarted(type: "text", name: nil))
                }
                if !chunk.isEmpty { await onEvent(.text(chunk)) }
            case "response.reasoning_summary_text.delta":
                if let chunk = event["delta"] as? String, !chunk.isEmpty { await onEvent(.thinking(chunk)) }
            case "response.output_item.done":
                if let item = event["item"] as? [String: Any] {
                    let index = event["output_index"] as? Int ?? items.count
                    items[index] = ClaudeClient.removingNulls(item)
                }
            case "response.completed", "response.incomplete":
                let response = event["response"] as? [String: Any]
                status = response?["status"] as? String ?? (type == "response.completed" ? "completed" : "incomplete")
                incompleteReason = (response?["incomplete_details"] as? [String: Any])?["reason"] as? String
            case "response.failed":
                let response = event["response"] as? [String: Any]
                let error = response?["error"] as? [String: Any]
                throw ClaudeError(message: error?["message"] as? String ?? "OpenAI couldn't finish this reply.")
            case "error":
                let message = (event["message"] as? String)
                    ?? ((event["error"] as? [String: Any])?["message"] as? String) ?? "OpenAI API error."
                throw ClaudeError(message: message)
            default:
                break
            }
        }

        var content: [[String: Any]] = []
        var invalid: Set<String> = []
        for index in items.keys.sorted() {
            guard let item = items[index] else { continue }
            switch item["type"] as? String {
            case "message":
                let text = (item["content"] as? [[String: Any]] ?? [])
                    .filter { $0["type"] as? String == "output_text" }
                    .compactMap { $0["text"] as? String }.joined()
                content.append(["type": "text", "text": text, "openai_item": item])
            case "function_call":
                let callID = item["call_id"] as? String ?? item["id"] as? String ?? "call_\(UUID().uuidString.prefix(12))"
                let raw = (item["arguments"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                var input: [String: Any] = [:]
                if !raw.isEmpty {
                    if let data = raw.data(using: .utf8),
                       let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        input = parsed
                    } else {
                        invalid.insert(callID)
                    }
                }
                content.append(["type": "tool_use", "id": callID, "name": item["name"] as? String ?? "",
                                "input": input, "openai_item": item])
            default:
                // Reasoning and anything else: not shown, but sent back on the next request.
                content.append(["type": "openai_item", "openai_item": item])
            }
        }

        let stopReason: String
        if content.contains(where: { $0["type"] as? String == "tool_use" }) {
            stopReason = "tool_use"
        } else if status == "incomplete" {
            stopReason = incompleteReason == "content_filter" ? "refusal" : "max_tokens"
        } else {
            stopReason = "end_turn"
        }
        return ClaudeResponse(content: content, stopReason: stopReason, invalidToolUseIDs: invalid)
    }

    /// Anthropic-style request body → Responses API body.
    static func translate(_ body: [String: Any]) -> [String: Any] {
        var input: [[String: Any]] = []
        for message in body["messages"] as? [[String: Any]] ?? [] {
            let role = message["role"] as? String ?? "user"
            if let text = message["content"] as? String {
                input.append(["role": role, "content": text])
                continue
            }
            for block in message["content"] as? [[String: Any]] ?? [] {
                let type = block["type"] as? String
                if role == "assistant" {
                    if let item = block["openai_item"] as? [String: Any] {
                        input.append(item)
                    } else if type == "text", let text = block["text"] as? String, !text.isEmpty {
                        input.append(["role": "assistant", "content": text])
                    } else if type == "tool_use" {
                        let arguments = (try? JSONSerialization.data(withJSONObject: block["input"] ?? [String: Any]()))
                            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                        input.append(["type": "function_call", "call_id": block["id"] as? String ?? "",
                                      "name": block["name"] as? String ?? "", "arguments": arguments])
                    }
                } else if type == "tool_result" {
                    let output = block["content"] as? String ?? ""
                    let isError = block["is_error"] as? Bool ?? false
                    input.append(["type": "function_call_output", "call_id": block["tool_use_id"] as? String ?? "",
                                  "output": isError ? "Error: \(output)" : output])
                } else if type == "text", let text = block["text"] as? String, !text.isEmpty {
                    input.append(["role": "user", "content": text])
                }
            }
        }

        var out: [String: Any] = [
            "model": body["model"] as? String ?? "",
            "input": input,
            "stream": true,
            "store": false,
            "include": ["reasoning.encrypted_content"],
        ]
        if let systemBlocks = body["system"] as? [[String: Any]] {
            let system = systemBlocks.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
            if !system.isEmpty { out["instructions"] = system }
        }
        // Server tools (web search) have a "type" and only exist on the Anthropic path.
        // strict is off: the tools have optional fields, which strict mode doesn't allow.
        let tools: [[String: Any]] = (body["tools"] as? [[String: Any]] ?? []).compactMap { tool in
            guard tool["type"] == nil, let name = tool["name"] as? String else { return nil }
            return [
                "type": "function",
                "name": name,
                "description": tool["description"] as? String ?? "",
                "parameters": tool["input_schema"] ?? ["type": "object", "properties": [String: Any]()],
                "strict": false,
            ]
        }
        if !tools.isEmpty { out["tools"] = tools }
        return out
    }
}
