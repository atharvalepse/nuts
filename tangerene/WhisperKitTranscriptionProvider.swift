//
//  WhisperKitTranscriptionProvider.swift
//  tangerene
//
//  On-device speech-to-text using WhisperKit (local Whisper via Core ML).
//  No API key and no network at transcription time — the only network use is a
//  one-time model download on first launch. Mirrors the buffer-then-transcribe
//  pattern of the OpenAI provider: audio is accumulated while the user holds
//  push-to-talk, then transcribed locally when they release the key.
//

import AVFoundation
import Foundation
import WhisperKit

struct WhisperKitTranscriptionProviderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Loads the WhisperKit model once and shares it across every transcription
/// session. The WhisperKit instance never leaves this actor, so non-Sendable
/// types (the pipeline, TranscriptionResult) never cross an isolation boundary —
/// callers only ever receive a plain `String` back.
actor SharedWhisperKitPipeline {
    static let shared = SharedWhisperKitPipeline()

    /// Whisper model variant. Overridable via the `WhisperKitModel` Info.plist
    /// key; defaults to the small English model for fast push-to-talk turnaround.
    private static let modelName = AppBundleConfiguration.stringValue(forKey: "WhisperKitModel") ?? "base.en"

    private var loadedPipeline: WhisperKit?
    private var inFlightLoad: Task<WhisperKit, Error>?

    /// Kicks off model loading ahead of the first transcription so the initial
    /// request doesn't eat the download/warm-up cost.
    func warmUp() async {
        _ = try? await pipeline()
    }

    /// Transcribes 16 kHz mono float samples to text entirely on-device.
    func transcribeToText(_ audioSamples: [Float]) async throws -> String {
        let pipeline = try await pipeline()
        let transcriptionResults = try await pipeline.transcribe(audioArray: audioSamples)
        return transcriptionResults
            .map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func pipeline() async throws -> WhisperKit {
        if let loadedPipeline {
            return loadedPipeline
        }
        if let inFlightLoad {
            return try await inFlightLoad.value
        }

        let loadTask = Task { () throws -> WhisperKit in
            try await WhisperKit(WhisperKitConfig(model: Self.modelName))
        }
        inFlightLoad = loadTask

        do {
            let pipeline = try await loadTask.value
            loadedPipeline = pipeline
            inFlightLoad = nil
            return pipeline
        } catch {
            inFlightLoad = nil
            throw error
        }
    }
}

final class WhisperKitTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "Whisper (on-device)"
    let requiresSpeechRecognitionPermission = false
    var isConfigured: Bool { true }
    var unavailableExplanation: String? { nil }

    init() {
        // Start downloading/loading the model now (at app launch) so the first
        // push-to-talk doesn't have to wait for it.
        Task { await SharedWhisperKitPipeline.shared.warmUp() }
    }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        return WhisperKitTranscriptionSession(
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
    }
}

private final class WhisperKitTranscriptionSession: BuddyStreamingTranscriptionSession {
    // Local transcription runs after key-up; allow generous time for the first
    // run (which may still be finishing the model download).
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 20.0

    private static let targetSampleRate = 16_000

    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let stateQueue = DispatchQueue(label: "com.tangerene.whisperkit.transcription")
    private let audioPCM16Converter = BuddyPCM16AudioConverter(
        targetSampleRate: Double(targetSampleRate)
    )

    private var bufferedPCM16AudioData = Data()
    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false
    private var isCancelled = false
    private var transcriptionTask: Task<Void, Never>?

    init(
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let audioPCM16Data = audioPCM16Converter.convertToPCM16Data(from: audioBuffer),
              !audioPCM16Data.isEmpty else {
            return
        }

        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.bufferedPCM16AudioData.append(audioPCM16Data)
        }
    }

    func requestFinalTranscript() {
        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.hasRequestedFinalTranscript = true

            let bufferedPCM16AudioData = self.bufferedPCM16AudioData
            self.transcriptionTask = Task { [weak self] in
                await self?.transcribeBufferedAudio(bufferedPCM16AudioData)
            }
        }
    }

    func cancel() {
        stateQueue.async {
            self.isCancelled = true
            self.bufferedPCM16AudioData.removeAll(keepingCapacity: false)
        }
        transcriptionTask?.cancel()
    }

    private func transcribeBufferedAudio(_ bufferedPCM16AudioData: Data) async {
        guard !Task.isCancelled else { return }

        let audioIsEmpty = stateQueue.sync {
            isCancelled || bufferedPCM16AudioData.isEmpty
        }
        if audioIsEmpty {
            deliverFinalTranscript("")
            return
        }

        let floatSamples = Self.convertPCM16DataToFloatSamples(bufferedPCM16AudioData)
        guard !floatSamples.isEmpty else {
            deliverFinalTranscript("")
            return
        }

        do {
            let transcriptText = try await SharedWhisperKitPipeline.shared.transcribeToText(floatSamples)
            guard !stateQueue.sync(execute: { isCancelled }) else { return }

            if !transcriptText.isEmpty {
                onTranscriptUpdate(transcriptText)
            }
            deliverFinalTranscript(transcriptText)
        } catch {
            guard !stateQueue.sync(execute: { isCancelled }) else { return }
            print("[WhisperKit] ❌ on-device transcription failed: \(error.localizedDescription)")
            onError(error)
        }
    }

    /// Converts little-endian PCM16 samples (from `BuddyPCM16AudioConverter`)
    /// into the normalized Float [-1, 1] array WhisperKit expects.
    private static func convertPCM16DataToFloatSamples(_ pcm16AudioData: Data) -> [Float] {
        let sampleCount = pcm16AudioData.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return [] }

        var floatSamples = [Float](repeating: 0, count: sampleCount)
        pcm16AudioData.withUnsafeBytes { rawBuffer in
            let int16Samples = rawBuffer.bindMemory(to: Int16.self)
            for sampleIndex in 0..<sampleCount {
                let sampleValue = Int16(littleEndian: int16Samples[sampleIndex])
                floatSamples[sampleIndex] = Float(sampleValue) / 32768.0
            }
        }
        return floatSamples
    }

    private func deliverFinalTranscript(_ transcriptText: String) {
        guard !hasDeliveredFinalTranscript else { return }
        hasDeliveredFinalTranscript = true
        onFinalTranscriptReady(transcriptText)
    }

    deinit {
        cancel()
    }
}
