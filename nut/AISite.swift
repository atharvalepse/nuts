//
//  AISite.swift
//  nut
//
//  Destinations Nut can hand off context to. Each site declares its base URL
//  and whether its composer reads a `?q=` query parameter (so we can open it
//  pre-filled) versus needing the clipboard-paste fallback.
//

import Foundation

enum AISite: String, CaseIterable, Identifiable {
    case chatgpt
    case perplexity
    case claude
    case gemini
    /// Whatever window/text field is currently focused. No URL — pure paste.
    case focusedWindow

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chatgpt:       return "ChatGPT"
        case .perplexity:    return "Perplexity"
        case .claude:        return "Claude"
        case .gemini:        return "Gemini"
        case .focusedWindow: return "Focused window"
        }
    }

    var systemImageName: String {
        switch self {
        case .chatgpt:       return "sparkle"
        case .perplexity:    return "magnifyingglass.circle"
        case .claude:        return "a.circle"
        case .gemini:        return "g.circle"
        case .focusedWindow: return "rectangle.inset.filled"
        }
    }

    /// Whether the site's composer reads a `?q=` URL parameter. Verified empirically:
    /// ChatGPT/Perplexity = yes; Claude/Gemini = unreliable (SPA + login redirect strips param).
    var supportsURLPrefill: Bool {
        switch self {
        case .chatgpt, .perplexity: return true
        case .claude, .gemini, .focusedWindow: return false
        }
    }

    /// Bare site URL (no prefill). Used as the fallback "just open the site" target.
    var baseURL: URL? {
        switch self {
        case .chatgpt:       return URL(string: "https://chatgpt.com/")
        case .perplexity:    return URL(string: "https://www.perplexity.ai/search")
        case .claude:        return URL(string: "https://claude.ai/new")
        case .gemini:        return URL(string: "https://gemini.google.com/app")
        case .focusedWindow: return nil
        }
    }

    /// URL with the given prompt prefilled in the site's composer, if supported.
    /// Returns nil for sites that don't support prefill — caller should use the
    /// clipboard-paste fallback for those.
    func urlWithPrompt(_ prompt: String) -> URL? {
        guard supportsURLPrefill, let base = baseURL else { return nil }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "q", value: prompt)]
        return components?.url
    }
}
