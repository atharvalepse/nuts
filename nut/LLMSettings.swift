//
//  LLMSettings.swift
//  nut
//
//  Bring-Your-Own-Key configuration. Each user supplies their own AI provider +
//  API key, so the distributed app needs NO server/Worker and costs the developer
//  nothing. The key is stored in the macOS Keychain (never UserDefaults, never the
//  app bundle); the non-secret bits (provider, endpoint, model) live in UserDefaults.
//
//  This is what makes Nut self-contained: the app calls the provider directly
//  (see DirectVisionLLMClient), so there's no localhost/Worker dependency for
//  people who download it.
//

import Combine
import Foundation
import Security

/// The AI providers Nut offers as presets, plus a "custom" escape hatch for any
/// other OpenAI-compatible endpoint (self-hosted vLLM, LM Studio, etc.).
enum LLMProvider: String, CaseIterable, Identifiable {
    case openai
    case openrouter
    case ollama
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openai:     return "OpenAI"
        case .openrouter: return "OpenRouter"
        case .ollama:     return "Local (Ollama)"
        case .custom:     return "Custom endpoint"
        }
    }

    /// Default OpenAI-compatible chat-completions URL for this provider.
    var defaultEndpoint: String {
        switch self {
        case .openai:     return "https://api.openai.com/v1/chat/completions"
        case .openrouter: return "https://openrouter.ai/api/v1/chat/completions"
        case .ollama:     return "http://localhost:11434/v1/chat/completions"
        case .custom:     return ""
        }
    }

    /// A sensible default VISION model slug for this provider (Nut sends screenshots,
    /// so the model must be multimodal).
    var defaultModel: String {
        switch self {
        case .openai:     return "gpt-4o"
        case .openrouter: return "google/gemini-2.5-flash"
        case .ollama:     return "gemma4:31b"
        case .custom:     return ""
        }
    }

    /// Local Ollama needs no key; cloud providers do.
    var requiresAPIKey: Bool {
        switch self {
        case .ollama: return false
        case .openai, .openrouter, .custom: return true
        }
    }

    /// Short hint shown under the key field so users know where to get a key.
    var keyHint: String {
        switch self {
        case .openai:     return "Get a key at platform.openai.com/api-keys (needs billing)."
        case .openrouter: return "Get a key at openrouter.ai/keys (needs credits)."
        case .ollama:     return "No key needed — just have Ollama running with a vision model."
        case .custom:     return "Enter the bearer token your endpoint expects (if any)."
        }
    }
}

/// Observable, Keychain-backed store for the user's chosen provider/endpoint/model/key.
@MainActor
final class LLMSettings: ObservableObject {
    static let shared = LLMSettings()

    @Published private(set) var provider: LLMProvider
    @Published private(set) var endpoint: String
    @Published private(set) var model: String
    /// Held in memory for the UI; the durable copy lives in the Keychain.
    @Published private(set) var apiKey: String

    private static let keychainService = "com.nut.llm"
    private static let keychainAccount = "llmApiKey"
    private static let providerKey = "llmProvider"
    private static let endpointKey = "llmEndpoint"
    private static let modelKey = "llmModel"

    private init() {
        let savedProviderRaw = UserDefaults.standard.string(forKey: Self.providerKey)
        let resolvedProvider = LLMProvider(rawValue: savedProviderRaw ?? "") ?? .openai
        self.provider = resolvedProvider
        self.endpoint = UserDefaults.standard.string(forKey: Self.endpointKey) ?? resolvedProvider.defaultEndpoint
        self.model = UserDefaults.standard.string(forKey: Self.modelKey) ?? resolvedProvider.defaultModel
        self.apiKey = KeychainHelper.read(service: Self.keychainService, account: Self.keychainAccount) ?? ""
    }

    /// True once the user has supplied everything needed to make a call.
    var isConfigured: Bool {
        guard !endpoint.isEmpty, !model.isEmpty else { return false }
        if provider.requiresAPIKey {
            return !apiKey.isEmpty
        }
        return true
    }

    /// Persists a new configuration. Empty endpoint/model fall back to the
    /// provider's defaults; an empty key clears the Keychain entry.
    func update(provider: LLMProvider, endpoint: String, model: String, apiKey: String) {
        let resolvedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        self.provider = provider
        self.endpoint = resolvedEndpoint.isEmpty ? provider.defaultEndpoint : resolvedEndpoint
        self.model = resolvedModel.isEmpty ? provider.defaultModel : resolvedModel

        UserDefaults.standard.set(provider.rawValue, forKey: Self.providerKey)
        UserDefaults.standard.set(self.endpoint, forKey: Self.endpointKey)
        UserDefaults.standard.set(self.model, forKey: Self.modelKey)

        // Key handling — robust against the two mistakes that kept breaking the brain:
        // (1) saving the form with the key field left blank, and (2) pasting a URL
        // into the key field. In BOTH cases we KEEP the existing stored key instead
        // of wiping or overwriting it, so a good key can never be lost by accident.
        let keyLooksLikeURL = resolvedKey.lowercased().hasPrefix("http")
        if resolvedKey.isEmpty || keyLooksLikeURL {
            self.apiKey = KeychainHelper.read(service: Self.keychainService, account: Self.keychainAccount) ?? ""
        } else {
            self.apiKey = resolvedKey
            KeychainHelper.save(resolvedKey, service: Self.keychainService, account: Self.keychainAccount)
        }
    }
}

/// Minimal wrapper around the Security framework for storing one string secret.
/// Not actor-isolated so it can be called from any context.
enum KeychainHelper {
    static func save(_ value: String, service: String, account: String) {
        guard let valueData = value.data(using: .utf8) else { return }
        // Delete any existing item first so we always end up with a single entry.
        delete(service: service, account: account)
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: valueData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func read(service: String, account: String) -> String? {
        let readQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(readQuery as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    static func delete(service: String, account: String) {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)
    }
}
