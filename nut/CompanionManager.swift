//
//  CompanionManager.swift
//  nut
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Combine
import Foundation
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

/// An action the model has requested but is waiting for the user to approve
/// before Nut actually performs it on the user's behalf. Surfaced via the
/// notch island's consent UI — `Yes` runs it, `No`/Esc cancels.
struct PendingAction: Equatable {
    let action: ParsedAction
    /// CG-space (top-left origin, points) global click target for CLICK actions.
    /// Pre-computed at parse time so the executor doesn't have to re-walk the
    /// screenshot → display → CG-coordinate conversion at approval time.
    let screenSpaceClickLocation: CGPoint?
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    /// The latest spoken AI reply (without the [POINT] tag), shown in the notch island.
    @Published private(set) var latestResponseText: String = ""
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    /// An app-control action the model has requested (CLICK/TYPE/KEYS/SCROLL).
    /// Stays nil until the model emits one of those tags; the notch island
    /// observes this and shows a consent prompt — approve runs it, cancel
    /// (or Esc) clears it. Always-ask is the only v1 safety mode by design.
    @Published var pendingAction: PendingAction?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding demo.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    /// Base URL for the Cloudflare Worker proxy. All API requests route
    /// through this so keys never ship in the app binary.
    // Pointed at the LOCAL Worker (`wrangler dev` on this Mac) so it can reach the
    // local Ollama model at localhost:11434. To use the deployed cloud Worker
    // instead, swap this back to "https://nut-proxy.atharvalepse0129.workers.dev".
    private static let workerBaseURL = "http://localhost:8787"

    private lazy var claudeAPI: ClaudeAPI = {
        return ClaudeAPI(proxyURL: "\(Self.workerBaseURL)/chat", model: selectedModel)
    }()

    private let textToSpeechClient = AppleTTSClient()

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's transcript and Claude's response.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// Count of durable screen memories the user has saved (shown in the panel).
    @Published private(set) var savedMemoryCount: Int = 0

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// The Claude model used for voice responses. Persisted to UserDefaults.
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedClaudeModel") ?? "claude-sonnet-4-6"

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedClaudeModel")
        claudeAPI.model = model
    }

    /// User preference for whether the Nut cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isNutCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isNutCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isNutCursorEnabled")

    func setNutCursorEnabled(_ enabled: Bool) {
        isNutCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isNutCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Whether the user has submitted their email during onboarding.
    @Published var hasSubmittedEmail: Bool = UserDefaults.standard.bool(forKey: "hasSubmittedEmail")

    /// Submits the user's email to FormSpark.
    func submitEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }

        hasSubmittedEmail = true
        UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")

        NutAnalytics.identify(email: trimmedEmail)

        // Submit to FormSpark
        Task {
            var request = URLRequest(url: URL(string: "https://submit-form.com/YOUR_FORMSPARK_FORM_ID")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["email": trimmedEmail])
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    func start() {
        refreshAllPermissions()
        print("🔑 Nut start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        // Eagerly touch the Claude API so its TLS warmup handshake completes
        // well before the onboarding demo fires at ~40s into the video.
        _ = claudeAPI

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isNutCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .nutDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        NutAnalytics.trackOnboardingStarted()

        // Play Besaid theme at 60% volume, fade out after 1m 30s
        startOnboardingMusic()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and onboarding video
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .nutDismissPanel, object: nil)
        NutAnalytics.trackOnboardingReplayed()
        startOnboardingMusic()
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            print("⚠️ Nut: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            print("⚠️ Nut: Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps

        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            stepsRemaining -= 1
            player.volume -= volumeDecrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.stop()
                self?.onboardingMusicPlayer = nil
                self?.onboardingMusicFadeTimer = nil
            }
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            NutAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            NutAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            NutAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            NutAnalytics.trackAllPermissionsGranted()
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    NutAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isNutCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isNutCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .nutDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance
            currentResponseTask?.cancel()
            textToSpeechClient.stopPlayback()
            clearDetectedElementLocation()

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            NutAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        guard let self else { return }
                        self.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        NutAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        // If the user asked to remember the screen, save it to the
                        // memory layer instead of generating a normal spoken reply.
                        if let continuationTarget = Self.continuationTargetSite(in: finalTranscript) {
                            self.sendContextToAISite(continuationTarget)
                        } else if Self.isMemorySaveCommand(finalTranscript) {
                            self.saveCurrentScreenToMemory(note: finalTranscript)
                        } else {
                            self.sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript)
                        }
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            NutAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    // MARK: - Notch Island

    /// Sends a typed reply from the notch island through the same pipeline as voice.
    func submitTypedMessage(_ text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        lastTranscript = trimmedText
        if let continuationTarget = Self.continuationTargetSite(in: trimmedText) {
            sendContextToAISite(continuationTarget)
        } else if Self.isMemorySaveCommand(trimmedText) {
            saveCurrentScreenToMemory(note: trimmedText)
        } else {
            sendTranscriptToClaudeWithScreenshot(transcript: trimmedText)
        }
    }

    /// Starts push-to-talk from the island mic button (same path as the global shortcut).
    func beginVoiceReply() {
        handleShortcutTransition(.pressed)
    }

    /// Stops push-to-talk from the island mic button.
    func endVoiceReply() {
        handleShortcutTransition(.released)
    }

    // MARK: - App-Control Actions (always-ask)

    /// Runs the pending action through the executor. Called by the consent UI
    /// when the user taps "Yes". Clears `pendingAction` immediately so the
    /// consent UI dismisses, then dispatches to ActionExecutor.
    func approvePendingAction() {
        guard let pendingAction else { return }
        self.pendingAction = nil
        ActionExecutor.perform(pendingAction.action,
                               screenSpaceLocation: pendingAction.screenSpaceClickLocation)
        Task { try? await textToSpeechClient.speakText("done.") }
    }

    /// Discards the pending action without running it. Wired to the consent
    /// UI's "No" button and to the global Esc shortcut.
    func cancelPendingAction() {
        guard pendingAction != nil else { return }
        pendingAction = nil
        Task { try? await textToSpeechClient.speakText("okay, cancelled.") }
    }

    /// Converts a screenshot-space pixel coordinate (top-left origin) to a
    /// CG-space global screen point (also top-left, in points) suitable for
    /// CGEvent.post — needed so a CLICK at the same pixel the model "saw" lands
    /// at the right place on whichever connected display contains that capture.
    static func convertScreenshotPointToScreenSpace(
        _ screenshotPoint: CGPoint,
        capture: CompanionScreenCapture
    ) -> CGPoint {
        let screenshotWidth = CGFloat(capture.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(capture.screenshotHeightInPixels)
        let displayWidth = CGFloat(capture.displayWidthInPoints)
        let displayHeight = CGFloat(capture.displayHeightInPoints)
        let appKitDisplayFrame = capture.displayFrame  // NSScreen frame (AppKit, bottom-left origin)

        // Clamp to screenshot bounds
        let clampedX = max(0, min(screenshotPoint.x, screenshotWidth))
        let clampedY = max(0, min(screenshotPoint.y, screenshotHeight))

        // Scale screenshot pixels → display points (still top-left local)
        let displayLocalX = clampedX * (displayWidth / screenshotWidth)
        let displayLocalY = clampedY * (displayHeight / screenshotHeight)

        // Convert the AppKit display origin to a CG display origin. The main
        // screen (the one with the menu bar) sits at AppKit (0,0), and CG's
        // global Y inverts about its top edge — so any display's CG origin Y
        // is mainScreenHeight − appKitDisplayFrame.maxY.
        let mainScreenHeight = NSScreen.main?.frame.height ?? appKitDisplayFrame.maxY
        let cgDisplayOriginY = mainScreenHeight - appKitDisplayFrame.maxY

        return CGPoint(
            x: appKitDisplayFrame.origin.x + displayLocalX,
            y: cgDisplayOriginY + displayLocalY
        )
    }

    // MARK: - Context Injection (Send to other AIs)

    /// Phrases that signal the user wants to hand off the current context to another AI site.
    /// The transcript also has to mention WHICH site — handled in `continuationTargetSite(in:)`.
    private static let contextHandoffTriggerPhrases = [
        "continue this in", "continue in", "continue with",
        "send to", "send this to", "send context to",
        "open this in", "open in",
        "switch to", "switch this to",
        "hand off to", "handoff to"
    ]

    /// Identifies whether the user asked to hand off the current context to a
    /// specific AI site. Returns the target site, or nil if the transcript
    /// isn't a context-handoff command.
    static func continuationTargetSite(in transcript: String) -> AISite? {
        let normalizedTranscript = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTranscript.isEmpty else { return nil }

        let hasHandoffIntent = contextHandoffTriggerPhrases.contains { normalizedTranscript.contains($0) }
        guard hasHandoffIntent else { return nil }

        if normalizedTranscript.contains("chatgpt") || normalizedTranscript.contains("chat gpt") || normalizedTranscript.contains("gpt") {
            return .chatgpt
        }
        if normalizedTranscript.contains("perplexity") {
            return .perplexity
        }
        if normalizedTranscript.contains("claude") {
            return .claude
        }
        if normalizedTranscript.contains("gemini") || normalizedTranscript.contains("bard") {
            return .gemini
        }
        return nil
    }

    /// The system prompt for the context-handoff extraction step. The 1200-char
    /// cap is critical — it's what lets the handoff fit inside a URL parameter
    /// (so we can prefill ChatGPT/Perplexity without falling back to clipboard).
    private static let contextHandoffExtractionPrompt = """
    you are writing a compact context handoff so the user can continue in a different ai chat. in UNDER 1200 characters, describe: what they're working on, the key details visible on screen (filenames, app, what content is showing), and what they want to do next. write it as the opening message to a fresh assistant in the second person ("i'm working on..."). plain text only — no markdown, no lists, never any coordinate tags.
    """

    /// Captures the current screen, asks the model for a compact handoff
    /// summary, and either opens the target site with the summary prefilled in
    /// its URL (ChatGPT/Perplexity) or copies the summary to the clipboard and
    /// opens the bare site so the user (or the auto-paste delay) can ⌘V.
    func sendContextToAISite(_ targetSite: AISite) {
        currentResponseTask?.cancel()
        textToSpeechClient.stopPlayback()

        currentResponseTask = Task {
            voiceState = .processing
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                guard !Task.isCancelled else { return }

                let labeledImages = screenCaptures.map { capture in
                    (data: capture.imageData, label: capture.label)
                }

                let (rawHandoff, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.contextHandoffExtractionPrompt,
                    userPrompt: "extract a context handoff for me so i can continue this conversation in \(targetSite.displayName).",
                    onTextChunk: { _ in }
                )
                guard !Task.isCancelled else { return }

                // Strip any stray pointing tag — the model occasionally adds one
                // even when told not to. parsePointingCoordinates returns just
                // the speakable prose with the tag removed.
                let contextHandoffText = Self.parsePointingCoordinates(from: rawHandoff).spokenText
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                deliverContextHandoff(contextHandoffText, to: targetSite)
                voiceState = .idle
            } catch {
                voiceState = .idle
                print("⚠️ Context handoff failed: \(error)")
                try? await textToSpeechClient.speakText("sorry, i couldn't prepare that handoff.")
            }
        }
    }

    /// Routes the prepared handoff to the right transport for the target site:
    /// URL prefill if the site supports it AND the encoded URL fits the safe
    /// length budget, otherwise clipboard + open site + auto ⌘V after load.
    private func deliverContextHandoff(_ contextHandoffText: String, to targetSite: AISite) {
        // Special case: paste straight into whatever's focused right now.
        if targetSite == .focusedWindow {
            ContextInjector.pasteIntoFocused(text: contextHandoffText)
            Task { try? await textToSpeechClient.speakText("pasted that into your focused window.") }
            return
        }

        // Try URL prefill first if the site supports it and the URL stays under
        // 8KB (the safe "any modern server will accept it" threshold). If the
        // model wrote more than that, fall back to clipboard for this turn.
        if let prefilledURL = targetSite.urlWithPrompt(contextHandoffText),
           prefilledURL.absoluteString.count <= 8000 {
            NSWorkspace.shared.open(prefilledURL)
            Task { try? await textToSpeechClient.speakText("opened \(targetSite.displayName) with your context.") }
            return
        }

        // Fallback: copy + open site + auto-paste after the page loads.
        guard let bareSiteURL = targetSite.baseURL else { return }
        ContextInjector.openURLAndPaste(siteURL: bareSiteURL, text: contextHandoffText)
        Task { try? await textToSpeechClient.speakText("opened \(targetSite.displayName) and pasted your context.") }
    }

    // MARK: - Companion Prompt

    private static let companionVoiceResponseSystemPrompt = """
    you're nut, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    when you point, append a coordinate tag at the very end of your response, AFTER your spoken text. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.

    if pointing wouldn't help, append [POINT:none].

    examples:
    - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]"
    - user asks what html is: "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [POINT:none]"
    - user asks how to commit in xcode: "see that source control menu up top? click that and hit commit, or you can use command option c as a shortcut. [POINT:285,11:source control]"
    - element is on screen 2 (not where cursor is): "that's over on your other monitor — see the terminal window? [POINT:400,300:terminal:screen2]"

    actions (only when the user EXPLICITLY asks you to do something):
    sometimes the user will literally tell you to perform an action — "click the save button", "type my email", "press command s", "scroll down". in those cases ONLY, you may request an action and i will ask the user to confirm before actually running it.

    do NOT request an action when the user is just asking a question or asking you to point. when in doubt, point and explain — don't act.

    only ONE action per response, ever. pick either POINT or an action — not both. if you request an action, omit POINT.

    action formats (append at the very end of your response, after your spoken text):
    - [CLICK:x,y:label]            — left-click at screenshot pixel (x,y). label is the element name (like "save button"). use the same screenshot coordinate rules as POINT.
    - [TYPE:"the literal text":label] — type the quoted text into the focused field. keep typed text short.
    - [KEYS:cmd+s:label]           — send a keyboard shortcut. modifiers: cmd, ctrl, option, shift. e.g. cmd+shift+t.
    - [SCROLL:down:3:label]        — scroll up/down/left/right by N lines in the focused area.

    examples:
    - user says "click save": "okay, clicking save now. [CLICK:842,612:save button]"
    - user says "type my email": "sure, typing your email. [TYPE:"you@example.com":email field]"
    - user says "save the file": "saving. [KEYS:cmd+s:save]"
    - user says "scroll down a bit": "scrolling down. [SCROLL:down:5:main view]"
    - user just asks a question about what's on screen: no action, just answer (and optionally POINT).
    """

    // MARK: - Memory Layer

    /// Phrases that signal the user wants to save the current screen to memory.
    private static let memorySaveTriggerPhrases = [
        "remember this", "remember that", "remember my screen", "remember this screen",
        "save this", "save that", "save my screen", "save this screen",
        "save to memory", "save this to memory", "store this", "store that",
        "add this to memory", "keep this in memory", "note this down"
    ]

    /// Lightweight intent check — did the user ask to save the screen to memory?
    static func isMemorySaveCommand(_ transcript: String) -> Bool {
        let normalizedTranscript = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTranscript.isEmpty else { return false }
        return memorySaveTriggerPhrases.contains { normalizedTranscript.contains($0) }
    }

    private static let memorySummarySystemPrompt = """
    you are summarizing the user's screen so it can be saved to their long-term memory. write a concise, factual description in two to four sentences: which app or window is in focus, the key on-screen content (titles, names, what's being worked on), and what the user appears to be doing. plain text only — no markdown, no lists, and never include any coordinate or pointing tags. do not address the user; just describe the screen.
    """

    /// Captures the current screen(s), asks the model for a concise summary, and
    /// persists it to the local memory layer. Used by both the spoken "remember
    /// this" command and the "Remember this screen" panel button.
    func saveCurrentScreenToMemory(note: String) {
        currentResponseTask?.cancel()
        textToSpeechClient.stopPlayback()

        currentResponseTask = Task {
            voiceState = .processing
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                guard !Task.isCancelled else { return }

                let labeledImages = screenCaptures.map { capture in
                    (data: capture.imageData, label: capture.label)
                }

                let summaryUserPrompt = note.isEmpty
                    ? "summarize what's currently on my screen for my memory."
                    : "summarize what's currently on my screen for my memory. extra context from me: \(note)"

                let (rawSummary, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.memorySummarySystemPrompt,
                    userPrompt: summaryUserPrompt,
                    onTextChunk: { _ in }
                )
                guard !Task.isCancelled else { return }

                // Strip any stray pointing tag in case the model appends one.
                let screenSummary = Self.parsePointingCoordinates(from: rawSummary).spokenText
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                let primaryScreenshot = (screenCaptures.first(where: { $0.isCursorScreen })
                    ?? screenCaptures.first)?.imageData

                await NutMemoryStore.shared.saveMemory(
                    userNote: note,
                    screenSummary: screenSummary,
                    screenshotImageData: primaryScreenshot
                )
                savedMemoryCount = await NutMemoryStore.shared.count()

                voiceState = .idle
                try? await textToSpeechClient.speakText("got it — i saved that to your memory.")
            } catch {
                voiceState = .idle
                print("⚠️ Memory save failed: \(error)")
                try? await textToSpeechClient.speakText("sorry, i couldn't save that to memory.")
            }
        }
    }

    /// Refreshes the saved-memory count for the panel. Cheap; safe to call often.
    func refreshSavedMemoryCount() {
        Task { savedMemoryCount = await NutMemoryStore.shared.count() }
    }

    /// Appends the user's recent saved memories to the base system prompt so the
    /// model can recall them when relevant (the durable memory layer).
    private static func composeSystemPrompt(base: String, memories: [ScreenMemory]) -> String {
        guard !memories.isEmpty else { return base }

        let memoryDateFormatter = DateFormatter()
        memoryDateFormatter.dateFormat = "MMM d, h:mm a"

        var memoryLines: [String] = []
        for memory in memories {
            let timestamp = memoryDateFormatter.string(from: memory.createdAt)
            let trimmedNote = memory.userNote.trimmingCharacters(in: .whitespacesAndNewlines)
            let notePart = trimmedNote.isEmpty ? "" : " (user said: \"\(trimmedNote)\")"
            memoryLines.append("- [\(timestamp)]\(notePart) \(memory.screenSummary)")
        }

        let memoryHeader = "\n\nthe user has asked you to remember these things from earlier (most recent first). use them as background context when relevant to the current question, but don't bring them up unprompted:\n"
        return base + memoryHeader + memoryLines.joined(separator: "\n")
    }

    // MARK: - AI Response Pipeline

    /// Captures a screenshot, sends it along with the transcript to Claude,
    /// and plays the response aloud via ElevenLabs TTS. The cursor stays in
    /// the spinner/processing state until TTS audio begins playing.
    /// Claude's response may include a [POINT:x,y:label] tag which triggers
    /// the buddy to fly to that element on screen.
    private func sendTranscriptToClaudeWithScreenshot(transcript: String) {
        currentResponseTask?.cancel()
        textToSpeechClient.stopPlayback()

        currentResponseTask = Task {
            // Stay in processing (spinner) state — no streaming text displayed
            voiceState = .processing

            do {
                // Capture all connected screens so the AI has full context
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                guard !Task.isCancelled else { return }

                // Build image labels with the actual screenshot pixel dimensions
                // so Claude's coordinate space matches the image it sees. We
                // scale from screenshot pixels to display points ourselves.
                let labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                // Pass conversation history so Claude remembers prior exchanges
                let historyForAPI = conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                // Inject the user's recent saved memories (the durable memory layer)
                // so the model can recall what it was asked to remember.
                let recentMemories = await NutMemoryStore.shared.recentMemories(limit: 8)
                let systemPromptWithMemory = Self.composeSystemPrompt(
                    base: Self.companionVoiceResponseSystemPrompt,
                    memories: recentMemories
                )

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: systemPromptWithMemory,
                    conversationHistory: historyForAPI,
                    userPrompt: transcript,
                    onTextChunk: { _ in
                        // No streaming text display — spinner stays until TTS plays
                    }
                )

                guard !Task.isCancelled else { return }

                // Parse the [POINT:...] tag from Claude's response first.
                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
                // Then look for an action tag in the already-POINT-stripped text.
                // Actions and POINTs are mutually exclusive per the prompt, but if
                // both somehow appear, we honor POINT for the cursor and ACTION
                // for the executor — they don't conflict.
                let actionParseResult = ActionParser.parse(parseResult.spokenText)
                let spokenText = actionParseResult.spokenText
                latestResponseText = spokenText

                // Handle element pointing if Claude returned coordinates.
                // Switch to idle BEFORE setting the location so the triangle
                // becomes visible and can fly to the target. Without this, the
                // spinner hides the triangle and the flight animation is invisible.
                let hasPointCoordinate = parseResult.coordinate != nil
                if hasPointCoordinate {
                    voiceState = .idle
                }

                // Pick the screen capture matching Claude's screen number,
                // falling back to the cursor screen if not specified.
                let targetScreenCapture: CompanionScreenCapture? = {
                    if let screenNumber = parseResult.screenNumber,
                       screenNumber >= 1 && screenNumber <= screenCaptures.count {
                        return screenCaptures[screenNumber - 1]
                    }
                    return screenCaptures.first(where: { $0.isCursorScreen })
                }()

                if let pointCoordinate = parseResult.coordinate,
                   let targetScreenCapture {
                    // Claude's coordinates are in the screenshot's pixel space
                    // (top-left origin, e.g. 1280x831). Scale to the display's
                    // point space (e.g. 1512x982), then convert to AppKit global coords.
                    let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
                    let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
                    let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
                    let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
                    let displayFrame = targetScreenCapture.displayFrame

                    // Clamp to screenshot coordinate space
                    let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                    let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))

                    // Scale from screenshot pixels to display points
                    let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                    let displayLocalY = clampedY * (displayHeight / screenshotHeight)

                    // Convert from top-left origin (screenshot) to bottom-left origin (AppKit)
                    let appKitY = displayHeight - displayLocalY

                    // Convert display-local coords to global screen coords
                    let globalLocation = CGPoint(
                        x: displayLocalX + displayFrame.origin.x,
                        y: appKitY + displayFrame.origin.y
                    )

                    detectedElementScreenLocation = globalLocation
                    detectedElementDisplayFrame = displayFrame
                    NutAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)
                    print("🎯 Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
                } else {
                    print("🎯 Element pointing: \(parseResult.elementLabel ?? "no element")")
                }

                // If the model requested an executable action, stage it as a
                // PendingAction. The notch island shows a Yes/No consent prompt;
                // we never run an action without explicit user approval.
                if let parsedAction = actionParseResult.action {
                    var screenSpaceClickLocation: CGPoint? = nil
                    if case let .click(clickX, clickY, _) = parsedAction, let targetScreenCapture {
                        screenSpaceClickLocation = Self.convertScreenshotPointToScreenSpace(
                            CGPoint(x: clickX, y: clickY),
                            capture: targetScreenCapture
                        )
                    }
                    pendingAction = PendingAction(
                        action: parsedAction,
                        screenSpaceClickLocation: screenSpaceClickLocation
                    )
                    voiceState = .idle  // surface the consent UI right away
                    print("🛡️ Action pending approval: \(parsedAction.humanDescription)")
                }

                // Save this exchange to conversation history (with the point tag
                // stripped so it doesn't confuse future context)
                conversationHistory.append((
                    userTranscript: transcript,
                    assistantResponse: spokenText
                ))

                // Keep only the last 10 exchanges to avoid unbounded context growth
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                print("🧠 Conversation history: \(conversationHistory.count) exchanges")

                NutAnalytics.trackAIResponseReceived(response: spokenText)

                // Play the response via TTS. Keep the spinner (processing state)
                // until the audio actually starts playing, then switch to responding.
                if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do {
                        try await textToSpeechClient.speakText(spokenText)
                        // speakText returns after player.play() — audio is now playing
                        voiceState = .responding
                    } catch {
                        NutAnalytics.trackTTSError(error: error.localizedDescription)
                        print("⚠️ ElevenLabs TTS error: \(error)")
                        speakCreditsErrorFallback()
                    }
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
            } catch {
                NutAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error)")
                speakCreditsErrorFallback()
            }

            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    /// If the cursor is in transient mode (user toggled "Show Nut" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isNutCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while textToSpeechClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// Speaks a hardcoded error message using macOS system TTS when API
    /// credits run out. Uses NSSpeechSynthesizer so it works even when
    /// ElevenLabs is down.
    private func speakCreditsErrorFallback() {
        let utterance = "I'm all out of credits. Please reach out to the team and ask them to bring me back to life."
        let synthesizer = NSSpeechSynthesizer()
        synthesizer.startSpeaking(utterance)
        voiceState = .responding
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from Claude's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if Claude said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of Claude's response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    // MARK: - Onboarding Demo Sequence

    /// Runs the onboarding showcase (no video): after the welcome animation,
    /// Nut looks at the screen and points at something, then prompts the
    /// user to try push-to-talk. Called by BlueCursorView once the welcome
    /// message finishes.
    func beginOnboardingDemoSequence() {
        // Give the welcome message a beat to clear, then run the live demo
        // where Nut flies to something on screen and comments on it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            NutAnalytics.trackOnboardingDemoTriggered()
            self?.performOnboardingDemoInteraction()
        }

        // After the demo has had time to point and comment, stream in the
        // prompt inviting the user to try push-to-talk themselves.
        DispatchQueue.main.asyncAfter(deadline: .now() + 12.0) { [weak self] in
            self?.startOnboardingPromptStream()
        }
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're nut, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it to 6 words max, no exceptions.

    CRITICAL COORDINATE RULE: you MUST only pick elements near the CENTER of the screen. your x coordinate must be between 20%-80% of the image width. your y coordinate must be between 20%-80% of the image height. do NOT pick anything in the top 20%, bottom 20%, left 20%, or right 20% of the screen. no menu bar items, no dock icons, no sidebar items, no items near any edge. only things clearly in the middle area of the screen. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. all lowercase.

    format: your comment [POINT:x,y:label]

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    """

    /// Captures a screenshot and asks Claude to find something interesting to
    /// point at, then triggers the buddy's flight animation. Used during
    /// onboarding to demo the pointing feature while the intro video plays.
    func performOnboardingDemoInteraction() {
        // Don't interrupt an active voice response
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only send the cursor screen so Claude can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label + dimensionInfo)]

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    userPrompt: "look around my screen and find something interesting to point at",
                    onTextChunk: { _ in }
                )

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let pointCoordinate = parseResult.coordinate else {
                    print("🎯 Onboarding demo: no element to point at")
                    return
                }

                let screenshotWidth = CGFloat(cursorScreenCapture.screenshotWidthInPixels)
                let screenshotHeight = CGFloat(cursorScreenCapture.screenshotHeightInPixels)
                let displayWidth = CGFloat(cursorScreenCapture.displayWidthInPoints)
                let displayHeight = CGFloat(cursorScreenCapture.displayHeightInPoints)
                let displayFrame = cursorScreenCapture.displayFrame

                let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
                let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                let displayLocalY = clampedY * (displayHeight / screenshotHeight)
                let appKitY = displayHeight - displayLocalY
                let globalLocation = CGPoint(
                    x: displayLocalX + displayFrame.origin.x,
                    y: appKitY + displayFrame.origin.y
                )

                // Set custom bubble text so the pointing animation uses Claude's
                // comment instead of a random phrase
                detectedElementBubbleText = parseResult.spokenText
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = displayFrame
                print("🎯 Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" — \"\(parseResult.spokenText)\"")
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }
}
