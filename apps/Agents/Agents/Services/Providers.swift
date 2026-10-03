import Foundation

/// The AI companies an agent can run on. Anthropic uses its own Messages API;
/// every other provider speaks the OpenAI-compatible Chat Completions API.
enum Provider: String, CaseIterable, Identifiable, Codable {
    case anthropic, openai, gemini, xai, openrouter, mistral, deepseek, groq

    var id: String { rawValue }

    var name: String {
        switch self {
        case .anthropic: "Anthropic (Claude)"
        case .openai: "OpenAI"
        case .gemini: "Google Gemini"
        case .xai: "xAI (Grok)"
        case .openrouter: "OpenRouter"
        case .mistral: "Mistral"
        case .deepseek: "DeepSeek"
        case .groq: "Groq"
        }
    }

    /// Short name used in chat notices and errors.
    var shortName: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openai: "OpenAI"
        case .gemini: "Google"
        case .xai: "xAI"
        case .openrouter: "OpenRouter"
        case .mistral: "Mistral"
        case .deepseek: "DeepSeek"
        case .groq: "Groq"
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .anthropic: "sk-ant-…"
        case .openai: "sk-…"
        case .gemini: "AIza…"
        case .xai: "xai-…"
        case .openrouter: "sk-or-…"
        case .groq: "gsk_…"
        case .mistral, .deepseek: "API key"
        }
    }

    var keyPage: URL {
        switch self {
        case .anthropic: URL(string: "https://console.anthropic.com/settings/keys")!
        case .openai: URL(string: "https://platform.openai.com/api-keys")!
        case .gemini: URL(string: "https://aistudio.google.com/apikey")!
        case .xai: URL(string: "https://console.x.ai")!
        case .openrouter: URL(string: "https://openrouter.ai/keys")!
        case .mistral: URL(string: "https://console.mistral.ai/api-keys")!
        case .deepseek: URL(string: "https://platform.deepseek.com/api_keys")!
        case .groq: URL(string: "https://console.groq.com/keys")!
        }
    }

    /// Base URL of the OpenAI-compatible API (unused for Anthropic).
    var baseURL: URL {
        switch self {
        case .anthropic: URL(string: "https://api.anthropic.com/v1")!
        case .openai: URL(string: "https://api.openai.com/v1")!
        case .gemini: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai")!
        case .xai: URL(string: "https://api.x.ai/v1")!
        case .openrouter: URL(string: "https://openrouter.ai/api/v1")!
        case .mistral: URL(string: "https://api.mistral.ai/v1")!
        case .deepseek: URL(string: "https://api.deepseek.com/v1")!
        case .groq: URL(string: "https://api.groq.com/openai/v1")!
        }
    }

    /// Only the Anthropic path has the built-in web search tool and adaptive thinking.
    var supportsWebSearch: Bool { self == .anthropic }

    static func from(_ raw: String) -> Provider { Provider(rawValue: raw) ?? .anthropic }

    /// Providers the user has added a key for, in display order.
    static var configured: [Provider] { allCases.filter { Keychain.key(for: $0) != nil } }
}

/// Per-provider preferences: which models exist (fetched with the user's key),
/// the default model for new agents, and whether the user agreed to send data there.
enum ProviderSettings {
    private static func key(_ name: String, _ provider: Provider) -> String { "provider.\(provider.rawValue).\(name)" }

    static func models(for provider: Provider) -> [String] {
        if provider == .anthropic { return ModelCatalog.options.map(\.id) }
        return UserDefaults.standard.stringArray(forKey: key("models", provider)) ?? []
    }

    static func setModels(_ models: [String], for provider: Provider) {
        UserDefaults.standard.set(models, forKey: key("models", provider))
    }

    static func defaultModel(for provider: Provider) -> String {
        let saved = UserDefaults.standard.string(forKey: key("default", provider)) ?? ""
        if !saved.isEmpty { return saved }
        if provider == .anthropic { return ModelCatalog.defaultModel }
        return models(for: provider).first ?? ""
    }

    static func setDefaultModel(_ model: String, for provider: Provider) {
        UserDefaults.standard.set(model, forKey: key("default", provider))
    }

    /// App Store guideline 5.1.2(i): the user must agree before personal data goes to a third-party AI.
    static func hasConsent(_ provider: Provider) -> Bool {
        UserDefaults.standard.bool(forKey: key("consent", provider))
            || NSUbiquitousKeyValueStore.default.bool(forKey: key("consent", provider))
    }

    static func setConsent(_ value: Bool, for provider: Provider) {
        UserDefaults.standard.set(value, forKey: key("consent", provider))
        NSUbiquitousKeyValueStore.default.set(value, forKey: key("consent", provider))
    }

    static func consentText(for provider: Provider) -> String {
        """
        To answer you, the app sends your messages, your agents' instructions and the facts saved in \
        "About me" to \(provider.name), using your own API key. Nothing goes to the app's developer. \
        \(provider.shortName) handles that data under its own privacy policy.
        """
    }

    /// Lists the models a key can use. Throws if the key is rejected, so it doubles as a key check.
    static func fetchModels(for provider: Provider, apiKey: String) async throws -> [String] {
        var request = URLRequest(url: provider.baseURL.appendingPathComponent("models"))
        request.timeoutInterval = 30
        if provider == .anthropic {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw ClaudeError(message: OpenAICompatClient.errorMessage(from: data, status: status, provider: provider))
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let items = (json?["data"] as? [[String: Any]]) ?? (json?["models"] as? [[String: Any]]) ?? []
        let sorted = items.sorted {
            (($0["created"] as? Double) ?? 0) > (($1["created"] as? Double) ?? 0)
        }
        let ids = sorted.compactMap { ($0["id"] as? String).map { $0.replacingOccurrences(of: "models/", with: "") } }
        return ids.filter(isChatModel)
    }

    /// Drops embedding, image, audio and moderation models from a provider's model list.
    private static func isChatModel(_ id: String) -> Bool {
        let lowered = id.lowercased()
        let excluded = ["embed", "tts", "whisper", "dall-e", "image", "audio", "moderation", "realtime",
                        "transcribe", "speech", "imagen", "veo", "aqa", "rerank", "guard", "ocr", "babbage", "davinci"]
        return !excluded.contains { lowered.contains($0) }
    }
}

/// Sends each request to the right provider for the agent that is speaking.
/// Keys are read once per turn, so an agent on a provider without a key fails with a clear message.
struct ClientPool {
    func stream(provider: Provider, body: [String: Any], betas: [String],
                onEvent: @MainActor (StreamEvent) -> Void) async throws -> ClaudeResponse {
        guard let key = Keychain.key(for: provider) else {
            throw ClaudeError(message: "Add your \(provider.name) API key in Settings to use this agent.")
        }
        guard ProviderSettings.hasConsent(provider) else {
            throw ClaudeError(message: "Open Settings and allow sending chats to \(provider.name) first.")
        }
        switch provider {
        case .anthropic:
            return try await ClaudeClient(apiKey: key).stream(body: body, betas: betas, onEvent: onEvent)
        default:
            return try await OpenAICompatClient(provider: provider, apiKey: key).stream(body: body, onEvent: onEvent)
        }
    }
}
