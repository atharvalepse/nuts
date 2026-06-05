# Nut - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar companion app. Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens a custom floating panel with companion voice controls. Uses push-to-talk (ctrl+option) to capture voice input, transcribes it on-device with WhisperKit (local Whisper), and sends the transcript + a screenshot of the user's screen to a self-hosted vision model (Qwen2.5-VL on GCP) through the Worker. The model responds with text (streamed via SSE), spoken aloud with Apple's on-device text-to-speech. A blue cursor overlay can fly to and point at UI elements the model references on any connected monitor.

Voice is fully on-device (no network for speech-to-text or text-to-speech). The only remote call is the LLM — your own vision model, reached through a Cloudflare Worker that adapts the app's Anthropic-format requests to your OpenAI-compatible endpoint. No model API key ships in the app.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat**: Self-hosted vision model (Qwen2.5-VL on GCP) via a Cloudflare Worker that adapts Anthropic ⇄ OpenAI, with SSE streaming. The app still speaks the Anthropic Messages API (`ClaudeAPI.swift`); the Worker translates, so swapping the model needs no app change. (The in-app Sonnet/Opus picker is now cosmetic — the Worker's `LLM_MODEL` decides which model serves.)
- **Speech-to-Text**: WhisperKit (on-device Whisper via Core ML) — default. AssemblyAI, OpenAI, and Apple Speech remain as optional providers (selectable via `VoiceTranscriptionProvider` in Info.plist). One-time model download on first launch.
- **Text-to-Speech**: Apple `AVSpeechSynthesizer` (on-device, offline)
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only CGEvent tap.
- **Element Pointing**: The model embeds `[POINT:x,y:label:screenN]` tags in responses. The overlay parses these, maps coordinates to the correct monitor, and animates the blue cursor along a bezier arc to the target.
- **Memory Layer**: On explicit request (voice command like "remember this", or the "Remember this screen" panel button), Nut captures the screen(s), has the model write a concise summary, and stores `{timestamp, note, summary, screenshot}` locally in Application Support via `NutMemoryStore` (an actor; JSON index + image files). The most recent memories are injected into the system prompt on later turns so the model can recall them. On-device only — nothing leaves the machine.
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: No-op seam in `NutAnalytics.swift` (PostHog dependency removed; instrumentation call sites kept — wire up your own backend by filling in the method bodies)

### LLM Adapter (Cloudflare Worker)

The app speaks the Anthropic Messages API. The Worker (`worker/src/index.ts`) translates each request into an OpenAI-compatible Chat Completions call, forwards it to your self-hosted vision model, and translates the streamed reply back into the slice of Anthropic SSE the app parses. The app is unchanged — only the Worker knows the brain is now your own model.

| Route | Upstream | Purpose |
|-------|----------|---------|
| `POST /chat` | your `LLM_ENDPOINT` (OpenAI-compatible) | Vision + streaming chat (Anthropic ⇄ OpenAI translation) |

Worker config: `LLM_ENDPOINT` + `LLM_MODEL` (vars in `wrangler.toml`), plus optional `LLM_API_KEY` (secret) if your endpoint needs auth. No Anthropic/OpenAI key required.

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor position, response text, waveform, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**Shared URLSession for AssemblyAI**: A single long-lived `URLSession` is shared across all AssemblyAI streaming sessions (owned by the provider, not the session). Creating and invalidating a URLSession per session corrupts the OS connection pool and causes "Socket is not connected" errors after a few rapid reconnections.

**Transient Cursor Mode**: When "Show Nut" is off, pressing the hotkey fades in the cursor overlay for the duration of the interaction (recording → response → TTS → optional pointing), then fades it out automatically after 1 second of inactivity.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `nutApp.swift` | ~89 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. No main window — the app lives entirely in the status bar. |
| `CompanionManager.swift` | ~1130 | Central state machine. Owns dictation, shortcut monitoring, screen capture, Claude API, Apple text-to-speech, the memory layer, and overlay management. Tracks voice state, conversation history, model selection, saved-memory count, and cursor visibility. Coordinates the push-to-talk → screenshot → model → TTS → pointing pipeline, plus the save-to-memory flow (intent detection, model summary, persistence, context injection). |
| `MenuBarPanelManager.swift` | ~243 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the floating companion panel (show/hide/position), installs click-outside-to-dismiss monitor. |
| `CompanionPanelView.swift` | ~800 | SwiftUI panel content for the menu bar dropdown. Shows companion status, push-to-talk instructions, model picker, permissions UI, a "Remember this screen" button (memory layer, with saved count), a feedback button, and quit. Dark aesthetic using `DS` design system. |
| `OverlayWindow.swift` | ~881 | Full-screen transparent overlay hosting the blue cursor, response text, waveform, and spinner. Handles cursor animation, element pointing with bezier arcs, multi-monitor coordinate mapping, and fade-out transitions. |
| `CompanionResponseOverlay.swift` | ~217 | SwiftUI view for the response text bubble and waveform displayed next to the cursor in the overlay. |
| `CompanionScreenCaptureUtility.swift` | ~132 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled image data for each connected display. |
| `BuddyDictationManager.swift` | ~866 | Push-to-talk voice pipeline. Handles microphone capture via `AVAudioEngine`, provider-aware permission checks, keyboard/button dictation sessions, transcript finalization, shortcut parsing, contextual keyterms, and live audio-level reporting for waveform feedback. |
| `BuddyTranscriptionProvider.swift` | ~105 | Protocol surface and provider factory for voice transcription backends. Resolves provider based on `VoiceTranscriptionProvider` in Info.plist — WhisperKit (default), AssemblyAI, OpenAI, or Apple Speech. |
| `WhisperKitTranscriptionProvider.swift` | ~210 | On-device speech-to-text via WhisperKit (local Whisper, Core ML). Buffers push-to-talk audio and transcribes locally on release; the WhisperKit pipeline is loaded once in a shared actor. One-time model download on first launch. |
| `AssemblyAIStreamingTranscriptionProvider.swift` | ~478 | Streaming transcription provider. Fetches temp tokens from the Cloudflare Worker, opens an AssemblyAI v3 websocket, streams PCM16 audio, tracks turn-based transcripts, and delivers finalized text on key-up. Shares a single URLSession across all sessions. |
| `OpenAIAudioTranscriptionProvider.swift` | ~317 | Upload-based transcription provider. Buffers push-to-talk audio locally, uploads as WAV on release, returns finalized transcript. |
| `AppleSpeechTranscriptionProvider.swift` | ~147 | Local fallback transcription provider backed by Apple's Speech framework. |
| `BuddyAudioConversionSupport.swift` | ~108 | Audio conversion helpers. Converts live mic buffers to PCM16 mono audio and builds WAV payloads for upload-based providers. |
| `GlobalPushToTalkShortcutMonitor.swift` | ~132 | System-wide push-to-talk monitor. Owns the listen-only `CGEvent` tap and publishes press/release transitions. |
| `ClaudeAPI.swift` | ~291 | Claude vision API client with streaming (SSE) and non-streaming modes. TLS warmup optimization, image MIME detection, conversation history support. |
| `OpenAIAPI.swift` | ~142 | OpenAI GPT vision API client. |
| `AppleTTSClient.swift` | ~100 | On-device text-to-speech via `AVSpeechSynthesizer` (free, offline). Drop-in replacement for the old ElevenLabs client — same `speakText`/`stopPlayback`/`isPlaying` surface. Picks the best available English voice. |
| `NutMemoryStore.swift` | ~150 | Local on-device memory layer (actor). Persists saved screen memories — model summary + user note + timestamp + screenshot — as a JSON index + image files in Application Support. Supplies recent memories for context injection; supports list/delete/clear. |
| `ElementLocationDetector.swift` | ~335 | Detects UI element locations in screenshots for cursor pointing. |
| `DesignSystem.swift` | ~880 | Design system tokens — colors, corner radii, shared styles. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
| `NutAnalytics.swift` | ~55 | Analytics seam. Event call sites are kept but are no-ops (PostHog removed) — fill in the methods to add your own analytics backend. |
| `WindowPositionManager.swift` | ~262 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |
| `AppBundleConfiguration.swift` | ~28 | Runtime configuration reader for keys stored in the app bundle Info.plist. |
| `worker/src/index.ts` | ~180 | Cloudflare Worker. One route: `/chat` — adapts the app's Anthropic-format request to an OpenAI-compatible call to your self-hosted vision model (`LLM_ENDPOINT`), and translates the streamed reply back to Anthropic SSE. |

## Build & Run

```bash
# Open in Xcode
open nut.xcodeproj

# Select the nut scheme, set signing team, Cmd+R to build and run

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

## Cloudflare Worker

```bash
cd worker
npm install

# Point it at your model: set LLM_ENDPOINT + LLM_MODEL in wrangler.toml.
# Only if your endpoint requires auth, add a bearer token as a secret:
npx wrangler secret put LLM_API_KEY

# Deploy
npx wrangler deploy

# Local dev (create worker/.dev.vars with your keys)
npx wrangler dev
```

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.
