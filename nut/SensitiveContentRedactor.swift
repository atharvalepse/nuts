//
//  SensitiveContentRedactor.swift
//  nut
//
//  Scrubs sensitive values (card numbers, government IDs, passwords, one-time
//  codes, API keys, account numbers) out of any text BEFORE it is persisted to
//  the local memory store / context journal, pushed to the GML cloud memory
//  layer, written to the action log, or shown in the autopilot step log.
//
//  This is the code-level backstop behind the prompt-level privacy rules — the
//  model is instructed never to transcribe secrets, but a regex pass guarantees
//  that anything that slips through is masked before it can be stored anywhere.
//

import Foundation

enum SensitiveContentRedactor {

    private struct RedactionRule {
        let regex: NSRegularExpression
        let replacementTemplate: String
    }

    /// Ordered rules; each is applied to the full text in sequence.
    private static let redactionRules: [RedactionRule] = {
        // (pattern, template) pairs. NSRegularExpression templates use $1 for groups.
        let rulePatterns: [(pattern: String, template: String, caseInsensitive: Bool)] = [
            // Payment-card-like digit runs: 13–19 digits, optionally space/dash separated.
            (#"\b(?:\d[ -]?){12,18}\d\b"#, "[card number hidden]", false),

            // US SSN shape 123-45-6789.
            (#"\b\d{3}-\d{2}-\d{4}\b"#, "[id number hidden]", false),

            // IBAN shape: country code + check digits + 11-30 alphanumerics.
            (#"\b[A-Z]{2}\d{2}[A-Za-z0-9]{11,30}\b"#, "[account number hidden]", false),

            // "password: hunter2", "pin is 4321", "otp = 998877" — keyword + separator + value.
            (#"\b(password|passcode|passwd|pwd|pin|cvv|cvc|otp|2fa code|verification code|security code)\b\s*(?:is|[:=])\s*("[^"]+"|\S+)"#,
             "$1: [hidden]", true),

            // "account number 12345678" / "routing #: 021000021".
            (#"\b(account|routing|swift)\s*(?:number|no\.?|#)\s*[:=]?\s*\d{6,}"#,
             "$1 number [hidden]", true),

            // Common API-key shapes (OpenAI, Groq, GitHub, AWS, Google, Cloudflare, Gemini).
            (#"\b(sk-[A-Za-z0-9_-]{16,}|gsk_[A-Za-z0-9]{16,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[A-Z0-9]{16}|AIza[A-Za-z0-9_-]{30,}|cfut_[A-Za-z0-9_-]{16,})\b"#,
             "[api key hidden]", false),
            (#"AQ\.[A-Za-z0-9_.\-]{20,}"#, "[api key hidden]", false)
        ]

        return rulePatterns.compactMap { rulePattern in
            let options: NSRegularExpression.Options = rulePattern.caseInsensitive ? [.caseInsensitive] : []
            guard let regex = try? NSRegularExpression(pattern: rulePattern.pattern, options: options) else {
                return nil
            }
            return RedactionRule(regex: regex, replacementTemplate: rulePattern.template)
        }
    }()

    /// Returns `text` with every sensitive-looking value replaced by a "[… hidden]"
    /// marker. Safe to call on empty strings; never throws.
    static func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var redactedText = text
        for rule in redactionRules {
            let fullRange = NSRange(redactedText.startIndex..., in: redactedText)
            redactedText = rule.regex.stringByReplacingMatches(
                in: redactedText,
                options: [],
                range: fullRange,
                withTemplate: rule.replacementTemplate
            )
        }
        return redactedText
    }
}
