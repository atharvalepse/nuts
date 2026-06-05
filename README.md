# Nut

Nut is an AI companion that lives in your macOS menu bar. It can see your screen, talk to you, and point at things with a friendly cursor — kind of like having a teacher sitting right next to you.

It's a native macOS app (SwiftUI + AppKit). Push-to-talk captures your voice, it's transcribed **on-device** (local Whisper), then the transcript plus a screenshot of your screen go to **your own vision model** (Qwen2.5-VL, self-hosted), and the response is **spoken back with your Mac's built-in voice**. The model can even fly the cursor to specific UI elements across multiple monitors.

![Nut — an AI buddy that lives on your Mac](nut-demo.gif)

> ⚠️ The demo above is placeholder footage from the original project and still shows the old UI. Re-record it and replace `nut-demo.gif` before you launch.

## Get started with Claude Code

The fastest way to get this running is with [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Open this folder and tell Claude:

```
Read CLAUDE.md. I want to get Nut running locally on my Mac.
Help me set up everything — the Cloudflare Worker pointed at my self-hosted model,
the proxy URLs, and getting it building in Xcode. Walk me through it.
```

## Manual setup

### Prerequisites

- macOS 14.2+ (for ScreenCaptureKit)
- Xcode 15+
- Node.js 18+ (for the Cloudflare Worker)
- A [Cloudflare](https://cloudflare.com) account (free tier works)
- A **vision model** (e.g. Qwen2.5-VL) served behind an **OpenAI-compatible endpoint** — your own, e.g. on GCP. No Anthropic/OpenAI key needed: voice runs on-device and the brain is your own model. (Speech-to-text via WhisperKit, text-to-speech via Apple — both on-device.)

### 1. Set up the Cloudflare Worker

The Worker is a small **adapter**: the app sends Anthropic-format requests, the Worker translates them to your model's OpenAI-compatible API and streams the reply back — so no model endpoint or token ships inside the app binary.

```bash
cd worker
npm install
```

Point it at your model — set `LLM_ENDPOINT` and `LLM_MODEL` in `worker/wrangler.toml`:

```toml
[vars]
LLM_ENDPOINT = "https://YOUR-GCP-ENDPOINT/v1/chat/completions"
LLM_MODEL = "Qwen/Qwen2.5-VL-7B-Instruct"
```

If your endpoint requires auth, add a bearer token as a secret:

```bash
npx wrangler secret put LLM_API_KEY
```

Deploy it:

```bash
npx wrangler deploy
```

It'll give you a URL like `https://nut-proxy.your-subdomain.workers.dev`. Copy that.

### 2. Run the Worker locally (for development)

```bash
cd worker
npx wrangler dev
```

This starts a local server (usually `http://localhost:8787`). `LLM_ENDPOINT`/`LLM_MODEL` come from `wrangler.toml`; if your endpoint needs auth, put the token in `worker/.dev.vars`:

```
LLM_API_KEY=...
```

### 3. Point the app at your Worker

The app ships with a placeholder Worker URL. Replace `your-worker-name.your-subdomain.workers.dev` with your real Worker URL:

```bash
grep -rn "your-worker-name.your-subdomain.workers.dev" nut/
```

You'll find it in `CompanionManager.swift` (the LLM chat). It also appears in `AssemblyAIStreamingTranscriptionProvider.swift`, but that only matters if you switch back to the optional AssemblyAI provider — by default transcription is on-device.

### 4. Open in Xcode and run

```bash
open nut.xcodeproj
```

In Xcode:
1. Select the `nut` scheme
2. Under **Signing & Capabilities**, set your own Development Team (it's blank by default) and change the bundle identifier from `com.yourcompany.nut` to your own
3. Hit **Cmd + R** to build and run

The app appears in your menu bar (not the dock). Click the icon, grant the permissions it asks for, and you're set.

> **First launch:** WhisperKit downloads its on-device speech model once (a few hundred MB), so the very first transcription may take a moment. After that, speech-to-text runs locally and offline.

### Permissions the app needs

- **Microphone** — push-to-talk voice capture
- **Accessibility** — the global keyboard shortcut (Control + Option)
- **Screen Recording** — screenshots when you use the hotkey
- **Screen Content** — ScreenCaptureKit access

## Architecture

Full technical breakdown lives in `CLAUDE.md`. Short version: a menu bar app (no dock icon) with two `NSPanel` windows — one for the control-panel dropdown, one for the full-screen transparent cursor overlay. Push-to-talk audio is transcribed on-device by WhisperKit, the transcript + a screenshot go to your self-hosted vision model via streaming SSE, and the response is spoken by Apple's on-device TTS. The model can embed `[POINT:x,y:label:screenN]` tags to make the cursor fly to specific UI elements across monitors. Only the model is remote — reached through a Cloudflare Worker that adapts the app's Anthropic-format requests to your OpenAI-compatible endpoint. Saying "remember this" (or hitting the **Remember this screen** button) saves a summary of the current screen to a local, on-device memory layer, which is fed back into the model's context on later questions.

## Project structure

```
nut/                  # Swift source
  CompanionManager.swift       # Central state machine
  CompanionPanelView.swift     # Menu bar panel UI
  ClaudeAPI.swift              # Anthropic-format client (the Worker adapts it to your model)
  AppleTTSClient.swift         # On-device text-to-speech (AVSpeechSynthesizer)
  WhisperKitTranscription*.swift # On-device speech-to-text (local Whisper)
  NutMemoryStore.swift   # Local memory layer (saved screen context)
  OverlayWindow.swift          # Cursor overlay
  BuddyDictation*.swift        # Push-to-talk pipeline
  NutAnalytics.swift     # Analytics seam (no-op; PostHog removed)
worker/                     # Cloudflare Worker proxy
  src/index.ts                 # One route: /chat — adapts Anthropic→OpenAI for your model
scripts/release.sh          # Build → sign → notarize → DMG → Sparkle appcast → GitHub Release
CLAUDE.md                   # Full architecture doc (AI agents read this)
```

## Releasing & auto-updates

`scripts/release.sh` automates build → sign → notarize → DMG → Sparkle appcast → GitHub Release. Before your **first** release, set up your own distribution identity:

- **Sparkle signing key** — generate your own EdDSA key pair and replace `SUPublicEDKey` in `nut/Info.plist` (the placeholder there is not yours, so updates won't verify until you do this).
- **Releases repo** — create a GitHub repo for your release DMGs + appcast, then update `SUFeedURL` in `nut/Info.plist` and `GITHUB_REPO` in `scripts/release.sh`.
- **Apple Developer** — set your Team and bundle identifier in Xcode (see step 4 above).

## License

MIT — see [LICENSE](LICENSE). Nut is a white-label built on the open-source [Clicky](https://github.com/farzaa/clicky) project by Farza. Per the MIT license, the original copyright notice is retained in `LICENSE`.
