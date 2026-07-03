//
//  CompanionManager.swift
//  nut
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AppKit
import ApplicationServices
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

/// One step in a guided tour: a narration segment plus an optional UI element
/// (in screenshot pixel space) the cursor should fly to while speaking it.
struct GuidedTourStep {
    let narration: String
    let coordinate: CGPoint?
    let label: String?
    let screenNumber: Int?
}

/// A multi-step task Nut runs on the user's behalf (autofill, click-through). Drives
/// the notch-island autopilot card; the actual queued action is held privately.
struct AgenticTask: Equatable {
    enum Status: Equatable {
        case awaitingApproval         // first action ready, waiting for the user to start
        case running                  // autopilot executing steps
        case awaitingSensitiveConfirm // paused on a high-stakes step (submit/pay/delete)
        case done
        case stopped
    }
    let goal: String
    var status: Status
    var log: [String]                 // completed-step descriptions, shown live
    var pendingStepLabel: String?     // the action awaiting approval / confirmation
    var stepNumber: Int
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

    /// The vision LLM client. Built from the user's own settings (bring-your-own-key),
    /// so the app calls the AI provider DIRECTLY — no Cloudflare Worker, no localhost
    /// bridge. Computed so it always reflects the latest provider/endpoint/key/model
    /// the user saved in Settings.
    // Cache one client (and its URLSession) and rebuild it ONLY when the user's
    // LLM settings actually change. Previously this rebuilt a fresh URLSession on
    // every access — and the proactive watcher hits it on a timer — which churned
    // sockets/TLS handshakes (the exact pattern CLAUDE.md warns against).
    private var cachedLLMClient: DirectVisionLLMClient?
    private var cachedLLMConfigKey: String?

    private var claudeAPI: DirectVisionLLMClient {
        let settings = LLMSettings.shared
        let configKey = "\(settings.endpoint)|\(settings.model)|\(settings.apiKey)"
        if let cached = cachedLLMClient, cachedLLMConfigKey == configKey {
            return cached
        }
        let client = DirectVisionLLMClient(
            endpoint: settings.endpoint,
            apiKey: settings.apiKey,
            model: settings.model
        )
        cachedLLMClient = client
        cachedLLMConfigKey = configKey
        return client
    }

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

    // selectedModel / setSelectedModel removed — the model is set via LLMSettings
    // (the BYOK settings UI). CompanionPanelView no longer renders a model picker.

    /// Whether the user has finished bring-your-own-key setup (provider + key + model).
    /// The panel uses this to gate the app behind a "add your key" prompt on first run.
    var isLLMConfigured: Bool {
        LLMSettings.shared.isConfigured
    }

    /// User preference for whether the Nut cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isNutCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isNutCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isNutCursorEnabled")

    // MARK: - Proactive Co-pilot

    /// When enabled, Nut periodically looks at the screen and offers help
    /// unprompted — but ONLY when it's genuinely useful. OFF by default, because
    /// ambient screen-watching is privacy-sensitive: it's strictly opt-in.
    @Published var isProactiveCopilotEnabled: Bool = UserDefaults.standard.bool(forKey: "isProactiveCopilotEnabled")

    /// The current proactive suggestion shown in the notch island, or nil if none.
    @Published var proactiveSuggestion: String?

    private var proactiveWatchTimer: Timer?
    private var lastProactiveOfferTime: Date?
    private var lastProactiveScreenshotData: Data?
    private let proactiveIntervalSeconds: TimeInterval = 90
    private let proactiveCooldownSeconds: TimeInterval = 180
    /// The in-flight proactive model call, tracked so it can be cancelled.
    private var proactiveCheckTask: Task<Void, Never>?

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

    // MARK: - Proactive Co-pilot control

    func setProactiveCopilotEnabled(_ enabled: Bool) {
        isProactiveCopilotEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isProactiveCopilotEnabled")
        if enabled {
            startProactiveWatch()
        } else {
            stopProactiveWatch()
            proactiveSuggestion = nil
        }
    }

    private func startProactiveWatch() {
        stopProactiveWatch()
        // Fire on an interval on the main run loop; each tick decides whether to
        // actually call the model (guarded by state + cooldown + change detection).
        let timer = Timer.scheduledTimer(withTimeInterval: proactiveIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runProactiveCheck() }
        }
        proactiveWatchTimer = timer
        print("👀 Proactive co-pilot: watching every \(Int(proactiveIntervalSeconds))s")

        // Run an initial check shortly after enabling so the user gets quick
        // feedback — the repeating timer otherwise wouldn't fire for 90s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.runProactiveCheck()
        }
    }

    private func stopProactiveWatch() {
        proactiveWatchTimer?.invalidate()
        proactiveWatchTimer = nil
    }

    /// One proactive tick: if conditions are right, capture the screen and ask the
    /// model whether anything is genuinely worth offering help with. Stays silent
    /// ([SKIP]) the vast majority of the time.
    private func runProactiveCheck() {
        // Don't interrupt: only when enabled, idle, nothing already pending, and
        // outside the cooldown window after the last offer.
        guard isProactiveCopilotEnabled else { return }
        guard voiceState == .idle else { return }
        guard proactiveSuggestion == nil, pendingAction == nil else { return }
        guard LLMSettings.shared.isConfigured else { return }
        if let lastOffer = lastProactiveOfferTime,
           Date().timeIntervalSince(lastOffer) < proactiveCooldownSeconds {
            return
        }

        proactiveCheckTask?.cancel()
        proactiveCheckTask = Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                guard let primaryData = (screenCaptures.first(where: { $0.isCursorScreen }) ?? screenCaptures.first)?.imageData else { return }

                // Change detection: if the screen is byte-identical to the last
                // checked frame, skip the model call entirely to save cost.
                if let lastData = lastProactiveScreenshotData, lastData == primaryData {
                    return
                }
                lastProactiveScreenshotData = primaryData

                let labeledImages = screenCaptures.map { (data: $0.imageData, label: $0.label) }
                let (rawResponse, _) = try await claudeAPI.analyzeImage(
                    images: labeledImages,
                    systemPrompt: Self.proactiveCopilotSystemPrompt,
                    userPrompt: "look at my screen. is there anything genuinely worth proactively helping with right now?"
                )

                guard !Task.isCancelled else { return }
                guard let suggestion = Self.parseProactiveSuggestion(rawResponse) else { return }
                // Re-check guards (state may have changed during the await).
                guard voiceState == .idle, proactiveSuggestion == nil, pendingAction == nil else { return }

                proactiveSuggestion = suggestion
                lastProactiveOfferTime = Date()
                print("💡 Proactive suggestion: \(suggestion)")
            } catch {
                // Proactive checks must NEVER nag with errors — fail silently.
                print("👀 Proactive check skipped: \(error.localizedDescription)")
            }
        }
    }

    /// User accepted a proactive offer — clear it and run a full interaction so
    /// Nut actually helps (answer + cursor pointing) with what it noticed.
    func engageProactiveSuggestion() {
        guard let suggestion = proactiveSuggestion else { return }
        proactiveSuggestion = nil
        lastTranscript = suggestion
        sendTranscriptToClaudeWithScreenshot(transcript: "you proactively offered: \"\(suggestion)\". go ahead and help me with that now.")
    }

    /// User dismissed the proactive offer.
    func dismissProactiveSuggestion() {
        proactiveSuggestion = nil
    }

    // MARK: - Ambient Context Capture (push intent to the memory layer)

    /// When enabled, Nut periodically captures the screen, has the model extract
    /// what the user is doing + their intent, and pushes it to the GML/gigzs cloud
    /// memory layer. OFF by default — ambient capture is privacy-sensitive.
    @Published var isAmbientCaptureEnabled: Bool = UserDefaults.standard.bool(forKey: "isAmbientCaptureEnabled")

    private var ambientCaptureTimer: Timer?
    private var ambientCaptureTask: Task<Void, Never>?
    private var lastAmbientScreenshotData: Data?
    private let ambientCaptureIntervalSeconds: TimeInterval = 90

    func setAmbientCaptureEnabled(_ enabled: Bool) {
        isAmbientCaptureEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isAmbientCaptureEnabled")
        if enabled { startAmbientCapture() } else { stopAmbientCapture() }
    }

    private func startAmbientCapture() {
        stopAmbientCapture()
        let timer = Timer.scheduledTimer(withTimeInterval: ambientCaptureIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runAmbientCapture() }
        }
        ambientCaptureTimer = timer
        print("📥 Ambient capture: watching every \(Int(ambientCaptureIntervalSeconds))s")
    }

    private func stopAmbientCapture() {
        ambientCaptureTimer?.invalidate()
        ambientCaptureTimer = nil
        ambientCaptureTask?.cancel()
        ambientCaptureTask = nil
    }

    /// True while an ambient tick is mid-flight. Used to SKIP the next timer tick
    /// instead of cancelling the running one — cancelling could drop a capture
    /// mid-ingest (the old behavior raced the 90s timer against slow networks).
    private var ambientCaptureInFlight = false

    /// One ambient tick: capture the screen, classify the user's context + INTENT
    /// (structured), append it to the local context journal (always), and sync it
    /// to the GML cloud layer when configured. The local journal is the source of
    /// truth — captures are never lost just because the cloud endpoint is down.
    private func runAmbientCapture() {
        guard isAmbientCaptureEnabled else { return }
        guard voiceState == .idle else { return }              // don't interfere with an active interaction
        guard LLMSettings.shared.isConfigured else { return }
        guard !ambientCaptureInFlight else { return }

        // Hard privacy gate: never even capture while a password manager or
        // authenticator is frontmost — those screens are secrets by definition.
        if let frontmostAppName = NSWorkspace.shared.frontmostApplication?.localizedName?.lowercased() {
            let sensitiveAppKeywords = ["1password", "keychain access", "bitwarden", "keepass",
                                        "dashlane", "lastpass", "authenticator", "authy", "proton pass"]
            if sensitiveAppKeywords.contains(where: { frontmostAppName.contains($0) }) {
                print("📥 Ambient capture skipped: sensitive app in focus")
                return
            }
        }

        ambientCaptureInFlight = true
        ambientCaptureTask = Task {
            defer { ambientCaptureInFlight = false }
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                guard let primaryData = (screenCaptures.first(where: { $0.isCursorScreen }) ?? screenCaptures.first)?.imageData else { return }

                // Change detection: skip the model call if the screen is unchanged.
                if let lastData = lastAmbientScreenshotData, lastData == primaryData { return }
                lastAmbientScreenshotData = primaryData

                let labeledImages = screenCaptures.map { (data: $0.imageData, label: $0.label) }
                let (rawResponse, _) = try await claudeAPI.analyzeImage(
                    images: labeledImages,
                    systemPrompt: Self.ambientCaptureSystemPrompt,
                    userPrompt: "classify the user's current context and intent from the screen."
                )
                guard !Task.isCancelled else { return }

                let extracted = Self.parsePointingCoordinates(from: rawResponse).spokenText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !extracted.isEmpty, !extracted.uppercased().contains("[SKIP]") else { return }

                // Parse the structured classification; redact any sensitive values
                // the model transcribed despite the prompt rules (code-level backstop).
                let classified = Self.parseAmbientContextClassification(extracted)
                let journalEntry = ContextJournalEntry(
                    timestamp: Date(),
                    appName: SensitiveContentRedactor.redact(classified.appName),
                    activity: SensitiveContentRedactor.redact(classified.activity),
                    intent: SensitiveContentRedactor.redact(classified.intent),
                    entities: classified.entities.map { SensitiveContentRedactor.redact($0) },
                    summary: SensitiveContentRedactor.redact(classified.summary)
                )

                // Local journal first — the living memory must survive GML being down.
                await ContextJournalStore.shared.append(journalEntry)

                // Then sync to the cloud memory layer (gigzs / GML) when configured.
                if GMLSettings.shared.isConfigured {
                    let appPart = journalEntry.appName.isEmpty ? "" : "[\(journalEntry.appName)] "
                    let intentPart = journalEntry.intent.isEmpty ? "" : " intent: \(journalEntry.intent)."
                    let gmlContent = "\(appPart)\(journalEntry.activity).\(intentPart) \(journalEntry.summary)"
                    await GMLMemoryClient.shared.ingest(
                        userQuery: journalEntry.intent.isEmpty ? "What is the user working on?" : journalEntry.intent,
                        assistantReply: gmlContent
                    )
                }
                print("📥 Ambient context → journal: \(journalEntry.appName) | \(journalEntry.intent.prefix(60))")
            } catch {
                // Ambient capture must never disrupt the user — fail silently.
                print("📥 Ambient capture skipped: \(error.localizedDescription)")
            }
        }
    }

    /// Parses the strict-JSON ambient classification the model returns. Tolerates
    /// code fences / stray prose around the JSON. Falls back to using the whole
    /// text as the summary when the model didn't produce valid JSON, so a capture
    /// is never thrown away over formatting.
    private static func parseAmbientContextClassification(
        _ text: String
    ) -> (appName: String, activity: String, intent: String, entities: [String], summary: String) {
        var jsonCandidate = text
        if let firstBraceIndex = jsonCandidate.firstIndex(of: "{"),
           let lastBraceIndex = jsonCandidate.lastIndex(of: "}"),
           firstBraceIndex < lastBraceIndex {
            jsonCandidate = String(jsonCandidate[firstBraceIndex...lastBraceIndex])
        }
        if let jsonData = jsonCandidate.data(using: .utf8),
           let parsedObject = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            let appName = (parsedObject["app"] as? String) ?? ""
            let activity = (parsedObject["activity"] as? String) ?? ""
            let intent = (parsedObject["intent"] as? String) ?? ""
            let entities = (parsedObject["entities"] as? [String]) ?? []
            let summary = (parsedObject["summary"] as? String) ?? ""
            if !activity.isEmpty || !summary.isEmpty {
                return (appName, activity, intent, entities, summary)
            }
        }
        return (appName: "", activity: "", intent: "", entities: [], summary: text)
    }

    private static let ambientCaptureSystemPrompt = """
    you are nut's ambient context classifier. look at the user's screen and respond with STRICT JSON only — no prose, no code fences:
    {"app": "<app or website in focus>", "activity": "<what is happening on screen, a short phrase>", "intent": "<what the user is most likely trying to accomplish right now>", "entities": ["<key names, titles, projects, people, or files visible>"], "summary": "<2-3 sentence third-person note for long-term memory>"}

    privacy rules — these override everything:
    - NEVER transcribe passwords, one-time codes, card or account numbers, CVVs, bank balances, or government ID numbers. write [hidden] in their place.
    - if the screen is primarily a login page, password manager, banking or payment page, or other highly sensitive content, respond EXACTLY [SKIP].
    - also respond EXACTLY [SKIP] for lock screens, empty desktops, or screens with nothing meaningful.
    """

    // MARK: - Agentic Tasks (autofill / multi-step automation)

    /// The active multi-step task Nut is running on the user's behalf, or nil.
    @Published var agenticTask: AgenticTask?

    /// The next action queued to run (awaiting approval / sensitive-confirm / next loop iteration).
    private var pendingAgenticAction: ParsedAction?
    /// Pre-computed CG-space click target for the queued action (CLICK only).
    private var pendingAgenticActionLocation: CGPoint?
    private var agenticTaskRunner: Task<Void, Never>?
    private let maxAgenticSteps = 8

    /// Phrases that mean "do a multi-step task for me" (vs a one-off "click X").
    private static let agenticTaskTriggerPhrases = [
        "autofill", "auto fill", "fill this", "fill in", "fill out", "fill the form",
        "fill my", "fill up", "complete this form", "complete the form",
        "do this for me", "do it for me", "click through", "go ahead and fill",
        "submit this form", "enter my"
    ]

    static func isAgenticTaskCommand(_ transcript: String) -> Bool {
        let normalized = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        return agenticTaskTriggerPhrases.contains { normalized.contains($0) }
    }

    /// Actions whose label/type implies an irreversible or high-stakes effect — these
    /// always pause for an explicit per-step confirmation, even during autopilot.
    private static func isSensitiveAction(_ action: ParsedAction) -> Bool {
        let sensitiveKeywords = ["delete", "remove", "send", "pay", "buy", "purchase",
                                 "confirm", "submit", "post", "publish", "trash",
                                 "discard", "order", "checkout", "transfer", "log out", "sign out"]
        let description = action.humanDescription.lowercased()
        return sensitiveKeywords.contains { description.contains($0) }
    }

    /// Starts a multi-step task: capture the screen, ask the model for the FIRST
    /// action, and surface a task-level approval card before doing anything.
    /// The user's saved profile (My Info vault), formatted to inject into autofill
    /// prompts so the agent fills forms with the user's real data.
    private var agenticProfileBlock: String {
        let context = UserProfileStore.shared.profile.promptContext
        return context.isEmpty ? "" : "\n\nthe user's saved info — use these EXACT values when a form field matches one of them:\n\(context)"
    }

    func startAgenticTask(goal: String) {
        currentResponseTask?.cancel()
        agenticTaskRunner?.cancel()
        textToSpeechClient.stopPlayback()

        currentResponseTask = Task {
            voiceState = .processing
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                guard !Task.isCancelled else { return }
                let labeledImages = screenCaptures.map { (data: $0.imageData, label: $0.label) }
                let (rawResponse, _) = try await claudeAPI.analyzeImage(
                    images: labeledImages,
                    systemPrompt: Self.agenticSystemPrompt,
                    userPrompt: "your goal: \(goal)\(agenticProfileBlock)\n\nlook at the screen. what is the SINGLE first action to begin? respond with exactly one action tag, or [DONE] if nothing is needed."
                )
                guard !Task.isCancelled else { return }
                voiceState = .idle

                let parsed = ActionParser.parse(rawResponse)
                guard let firstAction = parsed.action else {
                    latestResponseText = "I don't see anything I can do for that on this screen."
                    try? await textToSpeechClient.speakText("i don't see anything i can do for that on this screen.")
                    return
                }

                queueAgenticAction(firstAction, screenCaptures: screenCaptures)
                agenticTask = AgenticTask(
                    goal: goal,
                    status: .awaitingApproval,
                    log: [],
                    pendingStepLabel: SensitiveContentRedactor.redact(firstAction.humanDescription),
                    stepNumber: 0
                )
            } catch is CancellationError {
            } catch {
                voiceState = .idle
                speakAPIError(error)
            }
        }
    }

    /// Computes and stores the next action to run (+ its CG-space click target for CLICK).
    private func queueAgenticAction(_ action: ParsedAction, screenCaptures: [CompanionScreenCapture]) {
        var clickLocation: CGPoint? = nil
        if case let .click(clickX, clickY, _) = action {
            let cursorCapture = screenCaptures.first(where: { $0.isCursorScreen }) ?? screenCaptures.first
            if let cursorCapture {
                clickLocation = Self.convertScreenshotPointToScreenSpace(
                    CGPoint(x: clickX, y: clickY), capture: cursorCapture
                )
            }
        }
        pendingAgenticAction = action
        pendingAgenticActionLocation = clickLocation
    }

    /// User approved the task — begin the autopilot loop.
    func approveAgenticTask() {
        guard var task = agenticTask, task.status == .awaitingApproval else { return }
        task.status = .running
        agenticTask = task
        runAgenticLoop()
    }

    /// User confirmed a sensitive step — resume the loop (it runs the queued action).
    func confirmAgenticSensitiveStep() {
        guard var task = agenticTask, task.status == .awaitingSensitiveConfirm else { return }
        task.status = .running
        task.pendingStepLabel = nil
        agenticTask = task
        runAgenticLoop()
    }

    /// Stop the task immediately (Stop button / Esc).
    func stopAgenticTask() {
        agenticTaskRunner?.cancel()
        agenticTaskRunner = nil
        pendingAgenticAction = nil
        pendingAgenticActionLocation = nil
        if var task = agenticTask {
            task.status = .stopped
            task.pendingStepLabel = nil
            task.log.append("⏹ stopped")
            agenticTask = task
        }
        voiceState = .idle
        scheduleAgenticCardDismiss()
    }

    private func runAgenticLoop() {
        agenticTaskRunner?.cancel()
        agenticTaskRunner = Task {
            while let action = pendingAgenticAction,
                  var task = agenticTask,
                  task.status == .running,
                  task.stepNumber < maxAgenticSteps {
                if Task.isCancelled { return }

                // 1. Run the queued action. The description shown in the log / at the
                // cursor is redacted so typed secrets never appear in any UI surface.
                ActionExecutor.perform(action, screenSpaceLocation: pendingAgenticActionLocation)
                let safeActionDescription = SensitiveContentRedactor.redact(action.humanDescription)
                task.log.append("✓ \(safeActionDescription)")
                task.stepNumber += 1
                task.pendingStepLabel = nil
                agenticTask = task
                pendingAgenticAction = nil
                pendingAgenticActionLocation = nil
                // Narrate progress AT THE CURSOR so the user can watch what the
                // autopilot is doing without opening the island.
                latestResponseText = "autopilot — step \(task.stepNumber): \(safeActionDescription)"
                print("🤖 Agentic step \(task.stepNumber): \(safeActionDescription)")

                // 2. Let the UI react before screenshotting the result.
                try? await Task.sleep(nanoseconds: 1_300_000_000)
                if Task.isCancelled { return }

                // 3. Ask the model for the next step from the updated screen.
                do {
                    let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                    if Task.isCancelled { return }
                    let labeledImages = screenCaptures.map { (data: $0.imageData, label: $0.label) }
                    let logText = task.log.joined(separator: "\n")
                    let (rawResponse, _) = try await claudeAPI.analyzeImage(
                        images: labeledImages,
                        systemPrompt: Self.agenticSystemPrompt,
                        userPrompt: "your goal: \(task.goal)\(agenticProfileBlock)\n\nsteps completed:\n\(logText)\n\nlook at the screen now. what is the SINGLE next action? respond with exactly one action tag, or [DONE] if the goal is complete."
                    )
                    if Task.isCancelled { return }

                    let parsed = ActionParser.parse(rawResponse)
                    guard let nextAction = parsed.action else {
                        finishAgenticTask(success: true)
                        return
                    }
                    queueAgenticAction(nextAction, screenCaptures: screenCaptures)

                    // Sensitive next step → pause for explicit confirmation.
                    if Self.isSensitiveAction(nextAction) {
                        if var sensitiveTask = agenticTask {
                            sensitiveTask.status = .awaitingSensitiveConfirm
                            sensitiveTask.pendingStepLabel = SensitiveContentRedactor.redact(nextAction.humanDescription)
                            agenticTask = sensitiveTask
                        }
                        try? await textToSpeechClient.speakText("this step needs your okay: \(SensitiveContentRedactor.redact(nextAction.humanDescription))")
                        return
                    }
                    // Otherwise the while-loop continues with the new queued action.
                } catch is CancellationError {
                    return
                } catch {
                    finishAgenticTask(success: false, reason: "something went wrong")
                    return
                }
            }

            // Loop ended without an explicit finish → step cap reached.
            if let task = agenticTask, task.status == .running, task.stepNumber >= maxAgenticSteps {
                finishAgenticTask(success: false, reason: "reached the step limit")
            }
        }
    }

    private func finishAgenticTask(success: Bool, reason: String? = nil) {
        guard var task = agenticTask else { return }
        task.status = success ? .done : .stopped
        task.pendingStepLabel = nil
        task.log.append(success ? "✓ done" : "⏹ \(reason ?? "stopped")")
        agenticTask = task
        pendingAgenticAction = nil
        pendingAgenticActionLocation = nil
        voiceState = .idle
        let utterance = success ? "all done." : (reason ?? "i stopped.")
        Task { try? await textToSpeechClient.speakText(utterance) }
        scheduleAgenticCardDismiss()
    }

    private func scheduleAgenticCardDismiss() {
        Task {
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            if let status = agenticTask?.status,
               status != .running, status != .awaitingApproval, status != .awaitingSensitiveConfirm {
                agenticTask = nil
            }
        }
    }

    private static let agenticSystemPrompt = """
    you are nut, operating the user's mac to complete a task they asked for, ONE step at a time. you can see the screen and perform a single action per turn.

    respond with EXACTLY ONE action tag and nothing else:
    - [CLICK:x,y:label] — click an element. x,y are integer pixel coordinates in the screenshot's coordinate space (origin top-left). label is a short name for the element.
    - [TYPE:"the text":label] — type text into the currently focused field.
    - [KEYS:cmd+s:label] — press a keyboard shortcut (modifiers: cmd, ctrl, option, shift).
    - [SCROLL:down:3:label] — scroll up/down/left/right by N lines.
    - [OPEN:AppName] — open/launch an app by name (e.g. [OPEN:Safari], [OPEN:System Settings], [OPEN:Notes]). use this to start an app the task needs.

    think about the goal and the CURRENT screen, then pick the single next action that makes real progress. after each action i'll show you the updated screen and you choose the next one.

    when the goal is fully complete, respond with EXACTLY: [DONE]

    rules:
    - exactly ONE tag per turn, nothing else.
    - to fill a text field, first [CLICK] it to focus it, then on the NEXT turn [TYPE] into it.
    - only type values the user gave you (in the goal, or in the user's saved info above). never invent personal data like card numbers.
    - don't repeat an action that already worked. if the screen looks wrong or you're unsure, respond [DONE] instead of guessing.
    """

    private static let proactiveCopilotSystemPrompt = """
    you are nut, quietly watching the user's screen in the background. your job is to speak up ONLY when you can genuinely, specifically help — like a visible error message, a failed build or test, a stuck or confusing state, or an obvious mistake. the bar is HIGH: interrupting is annoying, so stay silent unless it's clearly worth it.

    if there is nothing clearly worth interrupting for, respond with EXACTLY: [SKIP]

    otherwise respond with ONE short, friendly, specific sentence offering help (max 18 words). no markdown, no tags, no coordinates. examples: "looks like that build failed on a missing import — want me to find it?" or "that error is a null reference — want me to explain it?"
    """

    /// Parses the proactive model response. Returns nil for [SKIP]/empty, else the suggestion.
    private static func parseProactiveSuggestion(_ response: String) -> String? {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.uppercased().contains("[SKIP]") || trimmed.uppercased() == "SKIP" { return nil }
        // Guard against the model rambling — cap the length.
        return trimmed.count > 160 ? String(trimmed.prefix(160)) : trimmed
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Whether the user has submitted their email during onboarding.
    /// Kept so existing UserDefaults values are respected (they skip the email step).
    @Published var hasSubmittedEmail: Bool = true  // Email gate removed — all users proceed directly.

    // Email submission removed. The gate is gone; hasSubmittedEmail is always true
    // so existing onboarding logic that checks it flows straight to the Start button.
    func submitEmail(_ email: String) {
        // No-op: email collection removed. Function retained so any stale call sites compile.
    }

    /// Bumped on every global left-mouse-down so the cursor overlay can play a
    /// cute click reaction (squish + sparkle).
    @Published var clickReactionCounter: Int = 0

    /// Bumped by the "daddy's home" wake word to make the mascot dance for joy.
    @Published var danceCelebrationCounter: Int = 0

    /// Token for the global mouse-down monitor that drives the click reaction.
    private var globalClickReactionMonitor: Any?

    /// Installs a global left-mouse-down monitor so the cursor mascot can react
    /// cutely to clicks anywhere on the system. Mouse global monitors don't need
    /// extra permission (unlike keyboard ones) and only observe — they never
    /// intercept the click.
    private func installGlobalClickReactionMonitor() {
        guard globalClickReactionMonitor == nil else { return }
        globalClickReactionMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Only react when the cursor companion is actually on screen.
                guard self.isNutCursorEnabled || self.isOverlayVisible else { return }
                self.clickReactionCounter &+= 1
            }
        }
    }

    func start() {
        // Silent sign-in (Gap 2): if a per-user akhort-config.json shipped in the
        // download zip is sitting in ~/Downloads (or next to the app), import the
        // GML origin + API key from it once, then delete it. Nothing to paste.
        GMLSettings.shared.importBundledConfigIfPresent()
        refreshAllPermissions()
        print("🔑 Nut start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        installGlobalClickReactionMonitor()
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

        // Resume the proactive co-pilot watcher if the user had it enabled.
        if isProactiveCopilotEnabled {
            startProactiveWatch()
        }
        // Resume ambient context capture if the user had it enabled.
        if isAmbientCaptureEnabled {
            startAmbientCapture()
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
        proactiveCheckTask?.cancel()
        proactiveCheckTask = nil
        stopProactiveWatch()
        stopAmbientCapture()
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

            // No AI brain configured yet → don't silently record audio and fail with
            // no feedback (the most common first-run dead-end). Tell the user to add
            // their key first, visibly at the cursor and spoken aloud.
            guard isLLMConfigured else {
                if !isOverlayVisible {
                    overlayWindowManager.hasShownOverlayBefore = true
                    overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                    isOverlayVisible = true
                }
                latestResponseText = "Open the Nut panel and add your AI key to start talking."
                voiceState = .responding
                let setupSynthesizer = NSSpeechSynthesizer()
                setupSynthesizer.startSpeaking("open the nut panel and add your a i key to start talking.")
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    if self.voiceState == .responding { self.voiceState = .idle }
                }
                return
            }

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
                        if Self.isStopCommand(finalTranscript) {
                            self.stopEverythingImmediately()
                        } else if Self.isDaddysHomeCommand(finalTranscript) {
                            self.activateAndCelebrate()
                        } else if let continuationTarget = Self.continuationTargetSite(in: finalTranscript) {
                            self.sendContextToAISite(continuationTarget)
                        } else if Self.isMemorySaveCommand(finalTranscript) {
                            self.saveCurrentScreenToMemory(note: finalTranscript)
                        } else if Self.isRecallDigestCommand(finalTranscript) {
                            self.generateMemoryDigest()
                        } else if Self.isAgenticTaskCommand(finalTranscript) {
                            self.startAgenticTask(goal: finalTranscript)
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
        if Self.isStopCommand(trimmedText) {
            stopEverythingImmediately()
        } else if Self.isDaddysHomeCommand(trimmedText) {
            activateAndCelebrate()
        } else if let continuationTarget = Self.continuationTargetSite(in: trimmedText) {
            sendContextToAISite(continuationTarget)
        } else if Self.isMemorySaveCommand(trimmedText) {
            saveCurrentScreenToMemory(note: trimmedText)
        } else if Self.isRecallDigestCommand(trimmedText) {
            generateMemoryDigest()
        } else if Self.isAgenticTaskCommand(trimmedText) {
            startAgenticTask(goal: trimmedText)
        } else {
            sendTranscriptToClaudeWithScreenshot(transcript: trimmedText)
        }
    }

    /// The master wake word: "daddy's home" (and close variants) instantly greets
    /// the user and makes the mascot dance.
    static func isDaddysHomeCommand(_ transcript: String) -> Bool {
        let normalized = transcript.lowercased()
        return normalized.contains("daddy's home") || normalized.contains("daddys home")
            || normalized.contains("daddy is home") || normalized.contains("daddy home")
            || normalized.contains("dad's home") || normalized.contains("dad is home")
    }

    /// The "daddy's home" reaction: pop the mascot on screen, make it dance for joy,
    /// greet the user warmly, then RECAP what they were recently working on and ask
    /// what they'd like to do next — like a personal assistant welcoming them back.
    func activateAndCelebrate() {
        currentResponseTask?.cancel()
        textToSpeechClient.stopPlayback()

        // Make sure the mascot is visible so the dance can actually be seen.
        if !isOverlayVisible {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }

        // Kick off the joyful dance in the overlay.
        danceCelebrationCounter &+= 1

        currentResponseTask = Task {
            // 1. Instant warm greeting (no model wait) so it feels immediate.
            let greeting = "daddy's home! i missed you. let me catch you up real quick."
            latestResponseText = greeting
            voiceState = .responding
            try? await textToSpeechClient.speakText(greeting)
            while textToSpeechClient.isPlaying {
                try? await Task.sleep(nanoseconds: 150_000_000)
                if Task.isCancelled { return }
            }
            if Task.isCancelled { return }

            // 2. Recap of recent work + ask what's next (built from memory).
            let recap = await buildWelcomeBackRecap()
            if Task.isCancelled { return }
            latestResponseText = recap
            voiceState = .responding
            try? await textToSpeechClient.speakText(recap)
            while textToSpeechClient.isPlaying {
                try? await Task.sleep(nanoseconds: 150_000_000)
                if Task.isCancelled { return }
            }
            if !Task.isCancelled { voiceState = .idle }
        }
    }

    /// Gathers the user's recent activity (local memories + GML + ambient journal)
    /// and has the model write a warm welcome-back recap that ends by asking what
    /// they'd like to work on next. Falls back to a plain greeting if empty/offline.
    private func buildWelcomeBackRecap() async -> String {
        let localMemories = await NutMemoryStore.shared.recentMemories(limit: 12)
        let gmlMemories = await GMLMemoryClient.shared.query(
            transcript: "what has the user been working on recently", limit: 8)
        let journalEntries = await ContextJournalStore.shared.recentEntries(limit: 12)

        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        var lines: [String] = []
        for memory in localMemories {
            let note = memory.userNote.trimmingCharacters(in: .whitespacesAndNewlines)
            let notePart = note.isEmpty ? "" : " (you said: \"\(note)\")"
            lines.append("- [\(formatter.string(from: memory.createdAt))]\(notePart) \(memory.screenSummary)")
        }
        lines.append(contentsOf: gmlMemories)
        for entry in journalEntries {
            let intentPart = entry.intent.isEmpty ? "" : " — \(entry.intent)"
            lines.append("- [\(formatter.string(from: entry.timestamp))] \(entry.appName): \(entry.activity)\(intentPart)")
        }

        guard !lines.isEmpty else {
            return "i don't have much of your history saved yet, but i'm all set and ready. what would you like to work on?"
        }

        let memoryBlock = lines.prefix(25).joined(separator: "\n")
        let recapPrompt = "the user just came back and said 'daddy's home'. here's what they've recently been working on:\n\n\(memoryBlock)\n\nin two or three warm, natural spoken sentences: welcome them back, recap what they were up to, then ask what they'd like to work on next."
        do {
            let (rawRecap, _) = try await claudeAPI.analyzeImage(
                images: [],
                systemPrompt: Self.welcomeBackSystemPrompt,
                userPrompt: recapPrompt
            )
            let recap = Self.parsePointingCoordinates(from: rawRecap).spokenText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return recap.isEmpty ? "welcome back! what would you like to work on next?" : recap
        } catch {
            return "welcome back! what would you like to work on next?"
        }
    }

    private static let welcomeBackSystemPrompt = """
    you are nut, a warm personal assistant greeting the user who just returned. write the way you'd actually talk (it's read aloud): warm, upbeat, natural. no markdown, no lists, no coordinate tags. keep it to two or three sentences — welcome them back, briefly recap what they were working on from the notes, then ask what they'd like to work on next.
    """

    /// Detects a "stop" command so the user can halt Nut immediately (stops speech,
    /// the current response, any running task, and the dance). Only short, clear
    /// stop utterances match, so a "stop" inside a longer sentence doesn't trigger.
    static func isStopCommand(_ transcript: String) -> Bool {
        let normalized = transcript.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: " .!?,"))
            .trimmingCharacters(in: .whitespaces)
        let stopPhrases: Set<String> = [
            "stop", "stop nut", "nut stop", "stop it", "stop talking", "stop please",
            "be quiet", "quiet", "shut up", "that's enough", "thats enough",
            "cancel", "nevermind", "never mind", "hush", "shush", "wait stop",
            "ok stop", "okay stop", "please stop"
        ]
        if stopPhrases.contains(normalized) { return true }
        // Also treat any SHORT utterance containing a strong stop word as a stop —
        // so "please stop nut", "ok stop talking" etc. work — without matching a
        // long sentence that merely mentions stopping.
        let wordCount = normalized.split(separator: " ").count
        if wordCount <= 4,
           normalized.contains("stop") || normalized.contains("shut up") || normalized.contains("be quiet") {
            return true
        }
        return false
    }

    /// Immediately halts everything Nut is doing on the user's command.
    func stopEverythingImmediately() {
        currentResponseTask?.cancel()
        textToSpeechClient.stopPlayback()
        clearDetectedElementLocation()
        if agenticTask != nil { stopAgenticTask() }
        pendingAction = nil
        proactiveSuggestion = nil
        latestResponseText = ""
        voiceState = .idle
        print("🛑 Stopped everything on user request.")
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

        // Some vision models return normalized 0–1 coordinates instead of pixels
        // (observed: Llama returned y=0.110). If a value is in (0,1], treat it as a
        // fraction of the screenshot dimension and scale it up to pixels.
        // Treat values strictly below 1.0 as normalized fractions; a legit pixel of
        // exactly 1 stays a pixel. NaN/inf are excluded by the < comparison.
        let pixelX = screenshotPoint.x > 0 && screenshotPoint.x < 1.0 ? screenshotPoint.x * screenshotWidth : screenshotPoint.x
        let pixelY = screenshotPoint.y > 0 && screenshotPoint.y < 1.0 ? screenshotPoint.y * screenshotHeight : screenshotPoint.y

        // Clamp to screenshot bounds
        let clampedX = max(0, min(pixelX, screenshotWidth))
        let clampedY = max(0, min(pixelY, screenshotHeight))

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

    who you are — this matters as much as anything below:
    you're a warm, genuine companion, like a thoughtful friend who happens to see the user's screen — not a robotic tool. you have two natural sides and you switch between them by reading the moment:
    - when they're doing something on screen, or ask how to do something → you're a sharp, concise screen helper: answer tightly, point at things, teach step by step.
    - when they just want to talk, vent, think a decision through, or need support → you're a present, caring friend: you listen first, you actually empathize, you reason things through with them, and you take your time. no rushing, no clipped one-liners, no pointing at the screen.
    being someone to talk to — emotional support, normal conversation, reasoning through a hard moment — is just as much your job as screen help. never brush past how someone feels just to get to a task.

    rules:
    - match your length to the moment. a quick factual question → one or two dense sentences. a how-to or "explain in depth" → a proper thorough walkthrough, no length limit. and when they're talking something through, sharing how they feel, or need support → respond like a real friend would: as long as it takes, warm and unhurried. never shrink a how-to or a heartfelt moment into a clipped one-liner.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming, thinking through a decision, or just being someone to talk to. if the user is stressed, stuck, sad, or excited, meet them with genuine warmth first, before any task.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    teaching & step-by-step guidance — this is core to what you do:
    when the user asks how to do something, how to set something up, or to teach/guide/walk them through a process (like "how do i set up ec2 on aws", "guide me through this", "teach me how to X"), DON'T answer in one line. walk them through it as clear, ordered steps, the way a patient mentor sitting right next to them would.
    - if the app, website, or page they need is already on screen, guide them ON the actual screen: describe each step and point at the exact button, menu, or field for it as you go — use multiple [POINT] tags, one per step, in order (see guided tours below).
    - if what they need ISN'T open yet (for example they ask about aws ec2 but the aws console isn't on screen), tell them what to open first, point at how to get there if it's visible, and say you'll walk them through each step once they're on the right screen.
    - keep each step concrete and in plain spoken language, and flow naturally from one step to the next. a real walkthrough can be long — that's good.

    element pointing — IMPORTANT, always do this:
    you have a cursor that physically moves on screen to point at UI elements. when you're helping with something on screen, point at the relevant element — it makes your help concrete and visual. when it's just a conversation, you don't need to point.

    ALWAYS end your response with either [POINT:x,y:label] or [POINT:none] — the app needs one of these two tags on every reply. when the user is doing something on screen or asking how to do something, point generously at the relevant element. BUT when it's a normal conversation, a personal or emotional moment, or pure general knowledge with nothing on screen to act on, just use [POINT:none] — never force a point into a heartfelt or chatty moment, it breaks the mood.

    examples of when to point (default to pointing in ALL these cases):
    - user asks about an app on screen → point at the app or relevant part of it
    - user asks a coding question and code is visible → point at the relevant line/area
    - user asks how to do something → point at the menu/button they should use
    - user asks what something is → point at it
    - anything is visible on screen that relates to the answer → point at it

    when you point, append a coordinate tag at the very end of your response, AFTER your spoken text. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). aim for the CENTER of the element, not its edge or corner — look carefully at exactly where it sits in the image. if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.

    if pointing wouldn't help, append [POINT:none].

    examples:
    - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]"
    - user asks what html is: "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [POINT:none]"
    - user asks how to commit in xcode: "see that source control menu up top? click that and hit commit, or you can use command option c as a shortcut. [POINT:285,11:source control]"
    - element is on screen 2 (not where cursor is): "that's over on your other monitor — see the terminal window? [POINT:400,300:terminal:screen2]"

    GUIDED TOURS — when explaining several things, give a tour:
    put a [POINT:x,y:label] right after EACH thing you describe, in the order you want the cursor to visit them. you can include MANY [POINT] tags in one response. the cursor will fly to each element in turn and your matching sentence will be spoken there. this is the best way to walk someone through a screen.
    tour example (user asks "explain my screen"): "up top you've got the toolbar with all your main actions [POINT:120,40:toolbar]. over on the left is the file sidebar where you navigate your project [POINT:60,300:sidebar]. and the big area in the middle is your editor [POINT:700,400:editor]. down at the bottom is the status bar showing build info [POINT:700,950:status bar]."

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

    // MARK: - Recall Digest ("catch me up")

    /// Phrases that ask Nut to recap what the user has been working on, drawing
    /// purely from saved memories (no screenshot needed).
    private static let recallDigestTriggerPhrases = [
        "catch me up", "what did i do", "what was i doing", "what have i been",
        "daily digest", "summarize my day", "summarise my day", "recap my",
        "what did i work on", "remind me what i", "what was i working on"
    ]

    static func isRecallDigestCommand(_ transcript: String) -> Bool {
        let normalized = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        return recallDigestTriggerPhrases.contains { normalized.contains($0) }
    }

    private static let memoryDigestSystemPrompt = """
    you are nut, the user's companion. they want a recap of what they've been working on, based on memories you saved earlier. you'll be given a list of saved screen memories with timestamps. write a warm, concise SPOKEN recap (3 to 5 sentences) of what they were doing, grouped by theme or project, most important first. speak directly to the user ("you were..."). plain text only — no markdown, no lists, no coordinate tags.
    """

    /// Produces a spoken recap of the user's recent saved memories (local + GML),
    /// without needing a screenshot — this is pure recall. Triggered by phrases
    /// like "catch me up" or "what did i do today".
    func generateMemoryDigest() {
        currentResponseTask?.cancel()
        textToSpeechClient.stopPlayback()

        currentResponseTask = Task {
            voiceState = .processing
            do {
                // Gather memories from both sources: the local store (recency) and
                // GML (semantic, if configured).
                let localMemories = await NutMemoryStore.shared.recentMemories(limit: 15)
                let gmlMemories = await GMLMemoryClient.shared.query(
                    transcript: "what has the user been working on recently",
                    limit: 10
                )

                // Build a plain-text memory list for the model to summarize.
                let memoryDateFormatter = DateFormatter()
                memoryDateFormatter.dateFormat = "MMM d, h:mm a"
                var memoryLines: [String] = []
                for memory in localMemories {
                    let timestamp = memoryDateFormatter.string(from: memory.createdAt)
                    let note = memory.userNote.trimmingCharacters(in: .whitespacesAndNewlines)
                    let notePart = note.isEmpty ? "" : " (you said: \"\(note)\")"
                    memoryLines.append("- [\(timestamp)]\(notePart) \(memory.screenSummary)")
                }
                memoryLines.append(contentsOf: gmlMemories)

                // Fold in the ambient context journal so "catch me up" reflects what
                // the user actually did, not just what they explicitly saved.
                let journalEntriesForDigest = await ContextJournalStore.shared.recentEntries(limit: 20)
                for journalEntry in journalEntriesForDigest {
                    let timestamp = memoryDateFormatter.string(from: journalEntry.timestamp)
                    let intentPart = journalEntry.intent.isEmpty ? "" : " — \(journalEntry.intent)"
                    memoryLines.append("- [\(timestamp)] (ambient) \(journalEntry.appName): \(journalEntry.activity)\(intentPart). \(journalEntry.summary)")
                }

                // Nothing saved yet — guide the user to start building memory.
                guard !memoryLines.isEmpty else {
                    let emptyMessage = "I don't have anything saved yet. Say \"remember this\" while looking at something and I'll start building your memory."
                    latestResponseText = emptyMessage
                    voiceState = .responding
                    try? await textToSpeechClient.speakText("i don't have anything saved yet. say remember this while looking at something, and i'll start building your memory.")
                    voiceState = .idle
                    return
                }

                let memoryBlock = memoryLines.joined(separator: "\n")
                let digestUserPrompt = "here are my saved memories. recap what i've been working on:\n\n\(memoryBlock)"

                // Pure text recall — no screenshot needed, so send an empty image list.
                let (rawDigest, _) = try await claudeAPI.analyzeImageStreaming(
                    images: [],
                    systemPrompt: Self.memoryDigestSystemPrompt,
                    userPrompt: digestUserPrompt,
                    onTextChunk: { [weak self] accumulatedText in
                        self?.latestResponseText = accumulatedText
                        self?.voiceState = .responding
                    }
                )
                guard !Task.isCancelled else { return }

                let digestText = Self.parsePointingCoordinates(from: rawDigest).spokenText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                latestResponseText = digestText

                if !digestText.isEmpty {
                    try await textToSpeechClient.speakText(digestText)
                }
            } catch is CancellationError {
                // Superseded by a newer interaction — nothing to report.
            } catch {
                print("⚠️ Memory digest failed: \(error)")
                speakAPIError(error)
            }

            // CRITICAL: always return to idle. If voiceState stays .responding,
            // the proactive co-pilot and other idle-gated features break forever.
            if !Task.isCancelled {
                voiceState = .idle
            }
        }
    }

    private static let memorySummarySystemPrompt = """
    you are summarizing the user's screen so it can be saved to their long-term memory. write a concise, factual description in two to four sentences: which app or window is in focus, the key on-screen content (titles, names, what's being worked on), and what the user appears to be doing. plain text only — no markdown, no lists, and never include any coordinate or pointing tags. do not address the user; just describe the screen.
    privacy rule — overrides everything: never transcribe passwords, one-time codes, card or account numbers, CVVs, bank balances, or government ID numbers. write [hidden] in their place.
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

                // Strip any stray pointing tag, then scrub sensitive values (cards,
                // IDs, passwords) before anything is persisted locally or to GML.
                let screenSummary = SensitiveContentRedactor.redact(
                    Self.parsePointingCoordinates(from: rawSummary).spokenText
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                )

                let primaryScreenshot = (screenCaptures.first(where: { $0.isCursorScreen })
                    ?? screenCaptures.first)?.imageData

                // Save locally first (fast, no network dependency).
                await NutMemoryStore.shared.saveMemory(
                    userNote: note,
                    screenSummary: screenSummary,
                    screenshotImageData: primaryScreenshot
                )
                savedMemoryCount = await NutMemoryStore.shared.count()

                // Also push to GML (cloud memory layer) if the user has configured it.
                // Fire-and-forget — local save already succeeded so a GML failure
                // is logged but doesn't change the user-facing outcome.
                Task {
                    await GMLMemoryClient.shared.ingest(
                        userQuery: note.isEmpty ? "Remember this screen" : note,
                        assistantReply: screenSummary
                    )
                }

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

    /// Builds the system prompt combining both local memories and GML cloud memories.
    /// GML memories (semantically retrieved) are listed first since they are more
    /// relevant to the current question; local recency-based memories follow.
    private static func composeSystemPromptWithGML(
        base: String,
        localMemories: [ScreenMemory],
        gmlMemories: [String]
    ) -> String {
        var sections: [String] = []

        // GML memories — semantically matched to the current transcript.
        if !gmlMemories.isEmpty {
            let gmlHeader = "\n\nrelevant memories from your cloud memory layer (GML — semantically matched to this question):\n"
            sections.append(gmlHeader + gmlMemories.joined(separator: "\n"))
        }

        // Local recent memories — time-ordered fallback / supplement.
        if !localMemories.isEmpty {
            let memoryDateFormatter = DateFormatter()
            memoryDateFormatter.dateFormat = "MMM d, h:mm a"
            let localLines = localMemories.map { memory -> String in
                let timestamp = memoryDateFormatter.string(from: memory.createdAt)
                let trimmedNote = memory.userNote.trimmingCharacters(in: .whitespacesAndNewlines)
                let notePart = trimmedNote.isEmpty ? "" : " (user said: \"\(trimmedNote)\")"
                return "- [\(timestamp)]\(notePart) \(memory.screenSummary)"
            }
            let localHeader = "\n\nrecent memories saved on this device:\n"
            sections.append(localHeader + localLines.joined(separator: "\n"))
        }

        guard !sections.isEmpty else { return base }

        let preamble = "\n\nuse these as background context when relevant, but don't bring them up unprompted:"
        return base + preamble + sections.joined()
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

                // Pull recent memories from both sources — local store (always available)
                // and GML (cloud, if configured). GML uses semantic search against the
                // transcript so results are more relevant than the local recency-only fallback.
                let recentLocalMemories = await NutMemoryStore.shared.recentMemories(limit: 8)
                let gmlMemories = await GMLMemoryClient.shared.query(transcript: transcript, limit: 5)
                let recentJournalEntries = await ContextJournalStore.shared.recentEntries(limit: 6)

                var systemPromptWithMemory = Self.composeSystemPromptWithGML(
                    base: Self.companionVoiceResponseSystemPrompt,
                    localMemories: recentLocalMemories,
                    gmlMemories: gmlMemories
                )

                // Living-memory context: what the user has been doing recently,
                // from the ambient context journal (classified app/activity/intent).
                if !recentJournalEntries.isEmpty {
                    let journalTimeFormatter = DateFormatter()
                    journalTimeFormatter.dateFormat = "MMM d, h:mm a"
                    let journalLines = recentJournalEntries.map { entry -> String in
                        let intentPart = entry.intent.isEmpty ? "" : " — intent: \(entry.intent)"
                        return "- [\(journalTimeFormatter.string(from: entry.timestamp))] \(entry.appName): \(entry.activity)\(intentPart)"
                    }
                    systemPromptWithMemory += "\n\nthe user's recent activity (ambient context journal, newest first):\n"
                        + journalLines.joined(separator: "\n")
                        + "\nuse this to understand what they've been working on when relevant, but don't recite it unprompted."
                }

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: systemPromptWithMemory,
                    conversationHistory: historyForAPI,
                    userPrompt: transcript,
                    onTextChunk: { [weak self] accumulatedText in
                        // Stream the response text to the cursor overlay bubble in real-time
                        // so the user can read along as TTS speaks. Also updates the notch island.
                        self?.latestResponseText = accumulatedText
                        self?.voiceState = .responding
                    }
                )

                guard !Task.isCancelled else { return }

                print("🤖 RAW MODEL RESPONSE: \(fullResponseText)")

                // Strip any executable action tag (CLICK/TYPE/KEYS/SCROLL) first —
                // those are handled separately via the consent flow.
                let actionParseResult = ActionParser.parse(fullResponseText)

                // Parse the response into an ordered guided tour: narration segments,
                // each optionally followed by a [POINT:x,y:label] the cursor flies to.
                let tourSteps = Self.parseGuidedTour(from: actionParseResult.spokenText)
                let stepsWithCoordinate = tourSteps.filter { $0.coordinate != nil }

                // Full spoken text (all narration joined, every tag stripped) for the
                // notch island display + conversation history.
                let spokenText = tourSteps
                    .map { $0.narration }
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                latestResponseText = spokenText

                print("🎯 Tour parsed: \(tourSteps.count) step(s), \(stepsWithCoordinate.count) with a point")

                // Record this exchange before playback so an interruption mid-tour
                // still keeps the history accurate.
                conversationHistory.append((
                    userTranscript: transcript,
                    assistantResponse: spokenText
                ))
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }
                NutAnalytics.trackAIResponseReceived(response: spokenText)

                // Auto-capture this interaction into the GML cloud memory layer
                // (fire-and-forget; silently skipped if GML isn't configured).
                // Redacted first — a spoken answer can quote sensitive on-screen values.
                Task {
                    await GMLMemoryClient.shared.ingest(
                        userQuery: SensitiveContentRedactor.redact(transcript),
                        assistantReply: SensitiveContentRedactor.redact(spokenText)
                    )
                }

                // Playback: if the model pointed at anything, run the guided tour —
                // fly the cursor to each element and speak its narration in turn.
                // Otherwise, just speak the whole answer once.
                if !stepsWithCoordinate.isEmpty {
                    await playGuidedTour(steps: tourSteps, screenCaptures: screenCaptures)
                } else if !spokenText.isEmpty {
                    voiceState = .responding  // show the answer bubble at the cursor while speaking
                    do {
                        try await textToSpeechClient.speakText(spokenText)
                    } catch {
                        speakAPIError(error)
                    }
                }

                // If the model requested an executable action, stage it for consent.
                if let parsedAction = actionParseResult.action {
                    let cursorCapture = screenCaptures.first(where: { $0.isCursorScreen }) ?? screenCaptures.first
                    var screenSpaceClickLocation: CGPoint? = nil
                    if case let .click(clickX, clickY, _) = parsedAction, let cursorCapture {
                        screenSpaceClickLocation = Self.convertScreenshotPointToScreenSpace(
                            CGPoint(x: clickX, y: clickY),
                            capture: cursorCapture
                        )
                    }
                    pendingAction = PendingAction(
                        action: parsedAction,
                        screenSpaceClickLocation: screenSpaceClickLocation
                    )
                    voiceState = .idle  // surface the consent UI right away
                    print("🛡️ Action pending approval: \(parsedAction.humanDescription)")
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted, nothing to report
            } catch {
                NutAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error)")
                speakAPIError(error)
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
        let utterance = "I'm having trouble reaching the AI. Please check your API key in the Nut panel."
        let synthesizer = NSSpeechSynthesizer()
        synthesizer.startSpeaking(utterance)
        voiceState = .responding
    }

    /// Inspects an API error and speaks a human-readable explanation. Handles the
    /// most common failure modes so the user knows what to fix without reading logs.
    func speakAPIError(_ error: Error) {
        let errorMessage = error.localizedDescription.lowercased()

        let utterance: String
        if errorMessage.contains("429") || errorMessage.contains("rate") || errorMessage.contains("quota") {
            // Gemini free tier: 15 requests per minute. Hit the limit → wait 60s.
            utterance = "I've hit a usage limit on the AI provider. Either wait a moment and try again, or add billing credits to your account."
            latestResponseText = "⚠️ Usage limit hit — wait a moment or add billing credits to your AI provider account."
        } else if errorMessage.contains("401") || errorMessage.contains("invalid api key") || errorMessage.contains("unauthorized") {
            utterance = "Your API key isn't working. Open the Nut panel and re-enter it in the AI Brain section."
            latestResponseText = "⚠️ Invalid API key — open the Nut panel → AI Brain → re-enter your key."
        } else if errorMessage.contains("503") || errorMessage.contains("service unavailable") {
            utterance = "The AI service is temporarily unavailable. Try switching to a different model in the Nut panel."
            latestResponseText = "⚠️ Service unavailable (503) — try a different model."
        } else if errorMessage.contains("404") || errorMessage.contains("not found") {
            // Wrong endpoint URL or model name — common when a local model isn't running.
            utterance = "I couldn't find your AI endpoint. Open the Nut panel and check the endpoint URL and model. If you're using a local model, make sure it's running."
            latestResponseText = "⚠️ Endpoint not found (404) — check the AI Brain URL & model. If it's a local model, make sure it's running."
        } else if errorMessage.contains("could not connect") || errorMessage.contains("connection refused")
                    || errorMessage.contains("hostname could not be found") || errorMessage.contains("could not be found")
                    || errorMessage.contains("connection") {
            // Endpoint unreachable (e.g. endpoint set to https://localhost with nothing running).
            utterance = "I can't reach your AI endpoint. If it's a local model, make sure it's running. Otherwise check the endpoint URL in the Nut panel."
            latestResponseText = "⚠️ Can't reach your AI endpoint — check the AI Brain URL, or start your local model."
        } else if errorMessage.contains("offline") || errorMessage.contains("network") || errorMessage.contains("timed out") || errorMessage.contains("timeout") {
            utterance = "I can't reach the internet right now. Check your connection and try again."
            latestResponseText = "⚠️ Connection problem — check your internet and try again."
        } else {
            utterance = "Something went wrong. Check the AI settings in the Nut panel."
            latestResponseText = "⚠️ Error: \(error.localizedDescription)"
        }

        let synthesizer = NSSpeechSynthesizer()
        synthesizer.startSpeaking(utterance)
        voiceState = .idle
        print("⚠️ API error spoken to user: \(error.localizedDescription)")
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

    // MARK: - Guided Tour

    /// Splits a model response into ordered tour steps. The text is divided on each
    /// [POINT:x,y:label(:screenN)] tag; the narration BEFORE each tag becomes that
    /// step's spoken segment and the tag becomes the element to fly to. Trailing
    /// narration after the last tag becomes a final point-less step. [POINT:none]
    /// yields a step with no coordinate.
    static func parseGuidedTour(from responseText: String) -> [GuidedTourStep] {
        let pattern = #"\[POINT:([^\]]+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [GuidedTourStep(narration: trimmed, coordinate: nil, label: nil, screenNumber: nil)]
        }

        let nsText = responseText as NSString
        let matches = regex.matches(in: responseText, options: [], range: NSRange(location: 0, length: nsText.length))

        if matches.isEmpty {
            let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [GuidedTourStep(narration: trimmed, coordinate: nil, label: nil, screenNumber: nil)]
        }

        var steps: [GuidedTourStep] = []
        var lastEnd = 0
        for match in matches {
            let tagRange = match.range
            let argsRange = match.range(at: 1)

            let narrationLength = tagRange.location - lastEnd
            let narration = narrationLength > 0
                ? nsText.substring(with: NSRange(location: lastEnd, length: narrationLength)).trimmingCharacters(in: .whitespacesAndNewlines)
                : ""

            let parsedArgs = parsePointArgs(nsText.substring(with: argsRange))
            steps.append(GuidedTourStep(
                narration: narration,
                coordinate: parsedArgs?.coordinate,
                label: parsedArgs?.label,
                screenNumber: parsedArgs?.screenNumber
            ))
            lastEnd = tagRange.location + tagRange.length
        }

        if lastEnd < nsText.length {
            let trailing = nsText.substring(from: lastEnd).trimmingCharacters(in: .whitespacesAndNewlines)
            if !trailing.isEmpty {
                steps.append(GuidedTourStep(narration: trailing, coordinate: nil, label: nil, screenNumber: nil))
            }
        }

        // Drop steps that are fully empty (no narration AND no coordinate).
        return steps.filter { !$0.narration.isEmpty || $0.coordinate != nil }
    }

    /// Parses the inside of a [POINT:...] tag: "x,y", "x,y:label", "x,y:label:screenN",
    /// or "none". Returns nil for "none" or an unparseable coordinate.
    private static func parsePointArgs(_ args: String) -> (coordinate: CGPoint, label: String?, screenNumber: Int?)? {
        let trimmed = args.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased() == "none" { return nil }

        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard let coordinatePart = parts.first else { return nil }

        let coordinateNumbers = coordinatePart.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard coordinateNumbers.count == 2,
              let x = Double(coordinateNumbers[0]),
              let y = Double(coordinateNumbers[1]),
              x.isFinite, y.isFinite else { return nil }

        let label = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : nil

        var screenNumber: Int? = nil
        if parts.count > 2 {
            let screenToken = parts[2].lowercased()
                .replacingOccurrences(of: "screen", with: "")
                .trimmingCharacters(in: .whitespaces)
            screenNumber = Int(screenToken)
        }

        return (CGPoint(x: x, y: y), label, screenNumber)
    }

    /// Converts a screenshot-space pixel coordinate (top-left origin) to a global
    /// AppKit screen point (bottom-left origin) that the cursor overlay can fly to.
    private func screenshotToAppKitGlobal(
        _ screenshotPoint: CGPoint,
        capture: CompanionScreenCapture
    ) -> (location: CGPoint, displayFrame: CGRect) {
        let screenshotWidth = CGFloat(capture.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(capture.screenshotHeightInPixels)
        let displayWidth = CGFloat(capture.displayWidthInPoints)
        let displayHeight = CGFloat(capture.displayHeightInPoints)
        let displayFrame = capture.displayFrame

        // Handle models that return normalized 0–1 coordinates instead of pixels.
        // Treat values strictly below 1.0 as normalized fractions; a legit pixel of
        // exactly 1 stays a pixel. NaN/inf are excluded by the < comparison.
        let pixelX = screenshotPoint.x > 0 && screenshotPoint.x < 1.0 ? screenshotPoint.x * screenshotWidth : screenshotPoint.x
        let pixelY = screenshotPoint.y > 0 && screenshotPoint.y < 1.0 ? screenshotPoint.y * screenshotHeight : screenshotPoint.y

        let clampedX = max(0, min(pixelX, screenshotWidth))
        let clampedY = max(0, min(pixelY, screenshotHeight))

        let displayLocalX = clampedX * (displayWidth / screenshotWidth)
        let displayLocalY = clampedY * (displayHeight / screenshotHeight)
        let appKitY = displayHeight - displayLocalY

        return (
            CGPoint(x: displayLocalX + displayFrame.origin.x, y: appKitY + displayFrame.origin.y),
            displayFrame
        )
    }

    /// Snaps a model-estimated screen point onto the actual UI element beneath it,
    /// using the macOS Accessibility API. Vision models — especially lighter ones like
    /// gemini-flash-lite — routinely land NEAR a control instead of on it. The
    /// accessibility tree knows each element's true frame, so we re-center the cursor
    /// on the small/medium control under the guess. This makes pointing feel accurate
    /// regardless of the brain model's eyesight.
    ///
    /// It fails safe: returns the original point untouched when Accessibility isn't
    /// granted, the app exposes no usable tree (many web/Electron views), or the only
    /// thing under the guess is a large container/window (snapping to a window center
    /// would be worse than the model's local guess).
    /// Snaps a model-estimated screen point onto the actual UI element beneath it
    /// via the Accessibility API, re-centering the cursor on the real control.
    ///
    /// The AX hit-test is a synchronous IPC call to the app under the cursor, which
    /// can stall for seconds if that app is hung (Xcode indexing, a crashed tab).
    /// So we run it OFF the main actor and race it against a short timeout: if it
    /// doesn't answer in time we just use the model's point. A frozen target app
    /// can therefore never freeze Nut's cursor or a guided tour.
    private func accessibilitySnappedPoint(
        forAppKitGlobalPoint appKitPoint: CGPoint,
        within displayFrame: CGRect
    ) async -> CGPoint {
        guard AXIsProcessTrusted() else { return appKitPoint }
        guard let primaryScreenHeight = NSScreen.screens.first?.frame.height, primaryScreenHeight > 0 else {
            return appKitPoint
        }

        let snapped: CGPoint? = await withTaskGroup(of: CGPoint?.self) { group in
            group.addTask {
                Self.accessibilityElementCenter(
                    forAppKitGlobalPoint: appKitPoint,
                    within: displayFrame,
                    primaryScreenHeight: primaryScreenHeight
                )
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 350_000_000)  // 350ms budget
                return nil
            }
            // Whichever finishes first wins; both return nil on "no snap" so either
            // way a nil result falls back to the model's point below.
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return snapped ?? appKitPoint
    }

    /// The off-main-actor AX hit-test. Returns the center of the small/medium UI
    /// element under `appKitPoint`, or nil if Accessibility finds nothing usable
    /// (or only a big container). Pure value-in/value-out — safe on a background task.
    nonisolated private static func accessibilityElementCenter(
        forAppKitGlobalPoint appKitPoint: CGPoint,
        within displayFrame: CGRect,
        primaryScreenHeight: CGFloat
    ) -> CGPoint? {
        // AXUIElementCopyElementAtPosition expects top-left-origin global (Quartz)
        // coordinates; our point is bottom-left-origin (AppKit). Flip Y about the
        // primary display's height.
        let quartzX = Float(appKitPoint.x)
        let quartzY = Float(primaryScreenHeight - appKitPoint.y)

        let systemWideElement = AXUIElementCreateSystemWide()
        var hitElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWideElement, quartzX, quartzY, &hitElement) == .success,
              let element = hitElement else {
            return nil
        }

        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionValue = positionRef, let sizeValue = sizeRef,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }

        var elementOriginQuartz = CGPoint.zero
        var elementSize = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &elementOriginQuartz)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &elementSize)

        // Reject degenerate elements and big containers/windows.
        guard elementSize.width > 4, elementSize.height > 4,
              elementSize.width <= displayFrame.width * 0.6,
              elementSize.height <= displayFrame.height * 0.6 else {
            return nil
        }

        let centerQuartz = CGPoint(x: elementOriginQuartz.x + elementSize.width / 2,
                                   y: elementOriginQuartz.y + elementSize.height / 2)
        let centerAppKit = CGPoint(x: centerQuartz.x,
                                   y: primaryScreenHeight - centerQuartz.y)

        // Only accept the snap when the element sits in the same neighborhood as the
        // guess; if the nearest element's center is far away we likely hit-tested an
        // unrelated control, so keep the model's point.
        let snapDistance = hypot(centerAppKit.x - appKitPoint.x, centerAppKit.y - appKitPoint.y)
        let maxSnapDistance = max(displayFrame.width, displayFrame.height) * 0.10
        guard snapDistance <= maxSnapDistance else { return nil }
        return centerAppKit
    }

    /// Plays a guided tour: for each step, flies the cursor to its element (if any),
    /// then speaks its narration, waiting for speech to finish before the next step.
    private func playGuidedTour(steps: [GuidedTourStep], screenCaptures: [CompanionScreenCapture]) async {
        for step in steps {
            if Task.isCancelled { clearDetectedElementLocation(); return }

            // Fly the cursor to this step's element first (if it has one).
            if let coordinate = step.coordinate {
                let targetCapture: CompanionScreenCapture? = {
                    if let screenNumber = step.screenNumber,
                       screenNumber >= 1 && screenNumber <= screenCaptures.count {
                        return screenCaptures[screenNumber - 1]
                    }
                    return screenCaptures.first(where: { $0.isCursorScreen }) ?? screenCaptures.first
                }()

                if let targetCapture {
                    voiceState = .idle  // show the cursor so its flight is visible
                    let converted = screenshotToAppKitGlobal(coordinate, capture: targetCapture)
                    // Snap the model's rough guess onto the real UI element under it
                    // so the cursor lands dead-center instead of just nearby.
                    let refinedLocation = await accessibilitySnappedPoint(
                        forAppKitGlobalPoint: converted.location,
                        within: converted.displayFrame
                    )
                    detectedElementBubbleText = step.label ?? "here"
                    detectedElementDisplayFrame = converted.displayFrame
                    detectedElementScreenLocation = refinedLocation
                    NutAnalytics.trackElementPointed(elementLabel: step.label)
                    print("🎯 Tour step → \"\(step.label ?? "element")\" at (\(Int(coordinate.x)),\(Int(coordinate.y)))")

                    // Let the cursor's flight animation arrive before narrating.
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled { clearDetectedElementLocation(); return }
                }
            }

            // Speak this step's narration; wait for it to finish before continuing.
            let narration = step.narration.trimmingCharacters(in: .whitespacesAndNewlines)
            if !narration.isEmpty {
                latestResponseText = narration
                voiceState = .responding  // keep the at-cursor text bubble visible while narrating
                do {
                    try await textToSpeechClient.speakText(narration)
                    // speakText returns immediately; poll until the audio finishes.
                    while textToSpeechClient.isPlaying {
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        if Task.isCancelled { clearDetectedElementLocation(); return }
                    }
                } catch is CancellationError {
                    // Interrupted (e.g. user started talking) — clean up the cursor
                    // and stop silently. Do NOT speak a bogus "something went wrong".
                    clearDetectedElementLocation()
                    return
                } catch {
                    // TTS failed mid-tour — surface it, clean up the cursor, and stop
                    // the tour instead of continuing with a frozen pointer.
                    clearDetectedElementLocation()
                    speakAPIError(error)
                    return
                }
            }

            // A short beat between elements so the tour doesn't feel rushed.
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        // Tour finished — return the cursor to following the mouse.
        clearDetectedElementLocation()
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
