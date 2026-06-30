//
//  AppleTTSClient.swift
//  nut
//
//  On-device text-to-speech using Apple's built-in AVSpeechSynthesizer.
//  Free, offline, and ships with macOS — no ElevenLabs/network dependency.
//  Drop-in replacement for the previous ElevenLabs client: it exposes the
//  same speakText / stopPlayback / isPlaying surface the companion pipeline
//  relies on.
//

import AVFoundation
import Foundation

@MainActor
final class AppleTTSClient: NSObject {
    private let speechSynthesizer = AVSpeechSynthesizer()

    /// Tracked explicitly (rather than reading `synthesizer.isSpeaking`) so the
    /// flag flips to true synchronously the instant we ask it to speak. The
    /// companion pipeline polls `isPlaying` right after calling `speakText`, and
    /// `AVSpeechSynthesizer.isSpeaking` can lag a beat behind `speak(_:)`.
    private var isCurrentlySpeaking = false

    /// Highest-quality English voice available on this Mac, picked once at init.
    private let preferredVoice: AVSpeechSynthesisVoice?

    override init() {
        self.preferredVoice = Self.bestAvailableEnglishVoice()
        super.init()
        speechSynthesizer.delegate = self
    }

    /// Speaks `text` aloud through the system audio output. Returns as soon as
    /// playback has been scheduled (matching the previous client's behavior),
    /// not when speech finishes — callers observe `isPlaying` for completion.
    func speakText(_ text: String) async throws {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        // Cut off anything already speaking so replies never overlap.
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: trimmedText)
        if let preferredVoice {
            utterance.voice = preferredVoice
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.postUtteranceDelay = 0

        isCurrentlySpeaking = true
        speechSynthesizer.speak(utterance)
        print("🔊 Apple TTS: speaking \(trimmedText.count) chars via \(preferredVoice?.name ?? "default voice")")
    }

    /// Whether speech is currently playing back.
    var isPlaying: Bool {
        isCurrentlySpeaking
    }

    /// Stops any in-progress speech immediately.
    func stopPlayback() {
        speechSynthesizer.stopSpeaking(at: .immediate)
        isCurrentlySpeaking = false
    }

    /// Prefers premium/enhanced neural voices when the user has downloaded them
    /// (System Settings → Accessibility → Spoken Content → System Voice), and
    /// falls back to a stock en-US voice otherwise.
    private static func bestAvailableEnglishVoice() -> AVSpeechSynthesisVoice? {
        let englishVoices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }

        // A voice the user explicitly chose (stored as its identifier in
        // UserDefaults) always wins — this lets the voice be changed without a
        // rebuild, just `defaults write com.atharvalepse.nut ttsVoiceIdentifier <id>`.
        if let chosenIdentifier = UserDefaults.standard.string(forKey: "ttsVoiceIdentifier"),
           !chosenIdentifier.isEmpty,
           let chosenVoice = AVSpeechSynthesisVoice(identifier: chosenIdentifier) {
            return chosenVoice
        }

        if let premiumVoice = englishVoices.first(where: { $0.quality == .premium }) {
            return premiumVoice
        }
        if let enhancedVoice = englishVoices.first(where: { $0.quality == .enhanced }) {
            return enhancedVoice
        }
        if let usEnglishVoice = englishVoices.first(where: { $0.language == "en-US" }) {
            return usEnglishVoice
        }
        return englishVoices.first ?? AVSpeechSynthesisVoice(language: "en-US")
    }
}

extension AppleTTSClient: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.isCurrentlySpeaking = false }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.isCurrentlySpeaking = false }
    }
}
