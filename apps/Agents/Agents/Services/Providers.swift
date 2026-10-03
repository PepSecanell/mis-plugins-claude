import Foundation
import SwiftData

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
        return suggestedModel(from: models(for: provider))
    }

    /// Newest model that can chat with tools. Lists are sorted newest first; specialised variants
    /// (search, deep research, Codex, audio, preview snapshots) can't run the agent loop.
    static func suggestedModel(from models: [String]) -> String {
        let unsuited = ["search", "research", "codex", "instruct", "computer-use", "audio", "realtime",
                        "preview", "vision", "learnlm", "gemma", "nano", "chat-latest", "-pro", "o1"]
        return models.first { id in !unsuited.contains { id.lowercased().contains($0) } } ?? models.first ?? ""
    }

    /// The provider agents move to when theirs has no key: the last one the user set up, else any with a key.
    static var preferred: Provider? {
        if let raw = UserDefaults.standard.string(forKey: "provider.preferred"),
           let provider = Provider(rawValue: raw), Keychain.key(for: provider) != nil {
            return provider
        }
        return Provider.configured.first
    }

    static func setPreferred(_ provider: Provider) {
        UserDefaults.standard.set(provider.rawValue, forKey: "provider.preferred")
    }

    /// Downloads the model list when this device doesn't have it yet (a key that arrived
    /// through iCloud Keychain from another device). Quietly does nothing if it fails.
    static func ensureModels(for provider: Provider) async {
        guard provider != .anthropic, models(for: provider).isEmpty,
              let apiKey = Keychain.key(for: provider),
              let fetched = try? await fetchModels(for: provider, apiKey: apiKey), !fetched.isEmpty else { return }
        setModels(fetched, for: provider)
    }

    static func setDefaultModel(_ model: String, for provider: Provider) {
        UserDefaults.standard.set(model, forKey: key("default", provider))
    }

    /// App Store guideline 5.1.2(i): the user must agree before personal data goes to a third-party AI.
    static func hasConsent(_ provider: Provider) -> Bool {
        #if DEBUG
        if SelfTest.assumeConsent { return true }
        #endif
        return UserDefaults.standard.bool(forKey: key("consent", provider))
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
        let hasDates = items.contains { (($0["created"] as? Double) ?? 0) > 0 }
        let ids = items.compactMap { ($0["id"] as? String).map { $0.replacingOccurrences(of: "models/", with: "") } }
        let sorted: [String]
        if hasDates {
            let created = Dictionary(items.compactMap { item -> (String, Double)? in
                guard let id = item["id"] as? String else { return nil }
                return (id.replacingOccurrences(of: "models/", with: ""), (item["created"] as? Double) ?? 0)
            }, uniquingKeysWith: { first, _ in first })
            sorted = ids.sorted { (created[$0] ?? 0) > (created[$1] ?? 0) }
        } else {
            // No dates (Gemini, some others): highest version number first, e.g. 3.8 before 2.5.
            sorted = ids.enumerated().sorted { lhs, rhs in
                let l = versionKey(lhs.element), r = versionKey(rhs.element)
                if l.isEmpty != r.isEmpty { return !l.isEmpty } // aliases like "-latest" go last
                return l != r ? l.lexicographicallyPrecedes(r, by: >) : lhs.offset < rhs.offset
            }.map(\.element)
        }
        return sorted.filter(isChatModel)
    }

    /// The numbers in a model id, e.g. "gemini-3.8-flash" → [3, 8].
    private static func versionKey(_ id: String) -> [Int] {
        guard let match = id.range(of: #"\d+(\.\d+)*"#, options: .regularExpression) else { return [] }
        return id[match].split(separator: ".").compactMap { Int($0) }
    }

    /// Drops embedding, image, audio and moderation models from a provider's model list.
    private static func isChatModel(_ id: String) -> Bool {
        let lowered = id.lowercased()
        let excluded = ["embed", "tts", "whisper", "dall-e", "image", "audio", "moderation", "realtime",
                        "transcribe", "speech", "imagen", "veo", "aqa", "rerank", "guard", "ocr", "babbage", "davinci"]
        return !excluded.contains { lowered.contains($0) }
    }
}

/// The provider said the agent's model doesn't exist or was retired.
struct ModelUnavailableError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    static func matches(_ text: String) -> Bool {
        let lowered = text.lowercased()
        guard lowered.contains("model") else { return false }
        return ["not found", "no longer available", "does not exist", "deprecated", "not supported",
                "decommissioned", "invalid model", "unknown model", "not available"].contains { lowered.contains($0) }
    }
}

/// The provider refused the API key (wrong, revoked or expired).
struct KeyRejectedError: LocalizedError {
    let provider: Provider
    let message: String
    var errorDescription: String? { message }
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
        do {
            switch provider {
            case .anthropic:
                return try await ClaudeClient(apiKey: key).stream(body: body, betas: betas, onEvent: onEvent)
            case .openai:
                // GPT-6 and later only take tools on the Responses API.
                return try await OpenAIResponsesClient(apiKey: key).stream(body: body, onEvent: onEvent)
            default:
                return try await OpenAICompatClient(provider: provider, apiKey: key).stream(body: body, onEvent: onEvent)
            }
        } catch let error as ClaudeError where ModelUnavailableError.matches(error.message) {
            throw ModelUnavailableError(message: error.message)
        } catch let error as ClaudeError where error.message.contains("API key was rejected") {
            throw KeyRejectedError(provider: provider, message: error.message)
        }
    }
}

/// Keeps every agent on a provider the user actually has a key for, so no agent fails with
/// "add your X key" after keys change or agents sync in from another device.
enum ProviderRouting {
    /// Moves one agent to the preferred provider if its own has no key, and fills in a missing model.
    @MainActor
    static func repair(_ agent: Agent) async {
        if Keychain.key(for: agent.providerKind) == nil, let fallback = ProviderSettings.preferred {
            agent.provider = fallback.rawValue
            agent.model = ""
        }
        let provider = agent.providerKind
        if agent.model.trimmingCharacters(in: .whitespaces).isEmpty {
            await ProviderSettings.ensureModels(for: provider)
            agent.model = ProviderSettings.defaultModel(for: provider)
        }
    }

    /// After the provider rejected the agent's model: pick the next suitable one and refresh the list.
    /// Returns false when there's nothing else to try.
    @MainActor
    static func replaceModel(of agent: Agent) async -> Bool {
        let provider = agent.providerKind
        let failed = agent.model
        if provider != .anthropic, let apiKey = Keychain.key(for: provider),
           let fetched = try? await ProviderSettings.fetchModels(for: provider, apiKey: apiKey), !fetched.isEmpty {
            ProviderSettings.setModels(fetched, for: provider)
        }
        let candidates = ProviderSettings.models(for: provider).filter { $0 != failed }
        let next = ProviderSettings.suggestedModel(from: candidates)
        guard !next.isEmpty else { return false }
        agent.model = next
        if ProviderSettings.defaultModel(for: provider) == failed {
            ProviderSettings.setDefaultModel(next, for: provider)
        }
        return true
    }

    @MainActor
    static func repairAll(in context: ModelContext) async {
        let agents = (try? context.fetch(FetchDescriptor<Agent>())) ?? []
        for agent in agents { await repair(agent) }
        try? context.save()
    }

    /// Puts every agent on one provider ("Use for all agents" in Settings).
    @MainActor
    static func moveAll(to provider: Provider, in context: ModelContext) {
        let model = ProviderSettings.defaultModel(for: provider)
        for agent in (try? context.fetch(FetchDescriptor<Agent>())) ?? [] {
            agent.provider = provider.rawValue
            agent.model = model
        }
        ProviderSettings.setPreferred(provider)
        try? context.save()
    }
}
