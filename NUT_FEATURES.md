# Nut — Features & How It Works

> Nut is a macOS menu-bar AI companion that **sees your screen, talks with you, points at things, remembers what matters, and (with your approval) acts on your behalf.** It lives in the menu bar and the camera-notch area — no dock icon, no main window.

This document is the single honest reference for **what Nut can do, how each part works, and what it deliberately can't do (yet).**

---

## 1. TL;DR

| | |
|---|---|
| **Platform** | macOS 14.2+ (Apple Silicon / Intel). **Mac only.** |
| **What it is** | Menu-bar AI assistant with screen vision, voice, a flying cursor, memory, and automation |
| **Voice** | Fully on-device (Whisper for hearing, Apple for speaking) — nothing leaves your Mac |
| **Brain** | **Bring-your-own-key** — you pick the AI (OpenAI / Gemini / OpenRouter / local Ollama / any OpenAI-compatible endpoint). Your key is stored in the macOS Keychain |
| **Distribution** | Runs from Xcode / a local build today. Not yet a signed public download (see §8) |
| **Privacy** | The only things that leave your Mac are (a) screenshots+text to *your chosen* AI provider, and (b) memory notes to *your* memory endpoint, if you connect one |

---

## 2. How Nut works (the pipeline)

```
        You hold Control+Option and speak
                     │
                     ▼
        🎙️ WhisperKit  (on-device speech → text)
                     │
                     ▼
        📸 ScreenCaptureKit  (screenshot of every monitor)
                     │
                     ▼
        🧠 Your AI model  (transcript + screenshot + memory + system prompt)
             via a direct OpenAI-compatible call (your key)
                     │
         ┌───────────┼───────────────┬──────────────┐
         ▼           ▼               ▼              ▼
     🗣️ Speak    👉 Fly cursor    🧠 Save/recall   🤖 Act
     (Apple TTS)  & point/tour     memory          (click/type)
```

**The "ears / brain / mouth" split:**
- 👂 **Ears** = WhisperKit (local Whisper, Core ML) — free, offline
- 🧠 **Brain** = your chosen LLM (the only remote/paid piece)
- 👄 **Mouth** = Apple `AVSpeechSynthesizer` — free, offline
- 🧠 **Memory** = local files + (optional) your cloud memory layer

---

## 3. What Nut CAN do (full feature catalog)

### 3.1 Talk to it from anywhere 🎙️
- **Push-to-talk:** hold **Control + Option** anywhere, speak, release. Works while any app is focused (background CGEvent tap).
- **Type instead:** the notch island has an inline "Reply…" field.
- Transcription is **on-device** (WhisperKit); first use downloads the model once (~150 MB), then it's instant + offline.

### 3.2 It sees your screen 👀
- On each request it screenshots **every connected monitor** (ScreenCaptureKit) and sends them to the model.
- Captures **only on demand** (hotkey / button), never silently — *unless* you turn on the optional ambient/proactive features (§3.9–3.10).

### 3.3 Spoken answers 🗣️
- Replies stream back and are **spoken aloud** with Apple's voice, written "for the ear" (short, conversational).
- Reply text also shows in a bubble next to the cursor and in the notch island.

### 3.4 The flying rocket cursor 🚀
- A custom rocket cursor follows your mouse and can **fly to specific UI elements** the model references (via `[POINT:x,y]` tags), mapped to the correct monitor.
- "Where's the source-control menu?" → it flies there and labels it.

### 3.5 Guided tours + visual highlights ✨
- Ask "give me a tour of my screen" → the cursor visits **multiple elements in sequence**, narrating each.
- Each stop draws a **pulsing spotlight ring** around the element (teaching mode).

### 3.6 The notch island HUD 🟦
- A mini pill at the camera notch / top-center that's invisible until needed.
- **Expands on hover**, and **auto-expands when a reply, suggestion, or task arrives.**
- Shows: the answer, an inline text reply, a hold-to-talk mic, plus consent cards for actions/tasks.

### 3.7 Memory layer 🧠
- Say **"remember this"** (or the panel button) → Nut captures the screen, has the model summarize it, and stores `{timestamp, note, summary, screenshot}` **locally** (Application Support).
- Recent memories are injected into the model's context on later questions.
- **Local store is capped (300)** and corruption-safe (backs up a bad index instead of wiping it).

### 3.8 "Catch me up" digest ⏱️
- Say **"catch me up"** / **"what did I do today?"** → Nut recaps your work from saved memories (local + cloud). No screenshot needed; works on any model.

### 3.9 Proactive co-pilot 👁️ *(opt-in, default OFF)*
- Periodically watches the screen and **offers help unprompted** only when it spots something genuinely useful (an error, a failed build, a stuck state).
- Surfaces in the island: "💡 Nut noticed something" → **Help me** / **Dismiss**.
- High bar, 180s cooldown, change-detection, never interrupts an active interaction.

### 3.10 Ambient context capture 📥 *(opt-in, default OFF)*
- Periodically captures the screen, has the model **extract your context + intent** (which app/site, what you're doing), and **pushes it to your cloud memory layer (GML / gigzs)**.
- Builds a searchable history of your work that "catch me up" can recall.

### 3.11 Context handoff to other AIs ↗️
- Say "send this to ChatGPT / Claude / Perplexity" or use the panel menu → Nut writes a compact handoff of your screen and opens that AI with the context (URL prefill where supported, clipboard + ⌘V otherwise).

### 3.12 Agentic autofill & clicking 🤖 *(with consent)*
- Say "autofill this form" / "do this for me" → Nut runs a **multi-step loop**: click → re-screenshot → next action → … until done.
- Safety: **task-level approval**, a **live step log**, an always-on **Stop**, an **8-step cap**, and a **per-step confirm on sensitive actions** (submit / pay / delete / send).

### 3.13 "My Info" vault 🪪
- Store your name / email / phone / address / company once (encrypted in Keychain).
- Autofill uses it so Nut fills forms with your **real data** without you dictating it each time.

### 3.14 Lives quietly in the background 🪶
- Menu-bar only (no dock icon), launches at login, non-activating panels that never steal focus.

---

## 4. Configuration (all in the menu-bar panel)

| Setting | What it's for |
|---|---|
| **AI Brain** | Provider + endpoint + model + API key (Keychain). OpenAI / OpenRouter / Gemini / Ollama / custom. |
| **GML Cloud Memory** | Your memory-layer API base URL + token (for ambient capture + recall) |
| **My Info** | Your personal details for autofill |
| **Proactive co-pilot** | Toggle ambient "offer help" watching |
| **Ambient memory capture** | Toggle context→memory capture |
| **Remember this screen / Catch me up / Send context to…** | One-tap memory + handoff |

**Permissions Nut needs:** Microphone, Accessibility, Screen Recording, Screen Content.

---

## 5. The independence stack (what makes Nut unusual)

| Layer | Uses | Where it runs |
|---|---|---|
| Speech→text | WhisperKit | On your Mac (free, offline) |
| Text→speech | Apple AVSpeechSynthesizer | On your Mac (free, offline) |
| Brain | Your chosen model (your key) | Remote (or local Ollama) |
| Memory | Local files + your cloud endpoint | On your Mac + your server |
| Analytics | **None** | — |

Net effect: the only outbound calls are to **your** AI provider and **your** memory endpoint. No third-party telemetry.

---

## 6. What Nut CANNOT do (honest limitations)

### Brain / accuracy
- **No built-in AI** — Nut has no model of its own. You must supply a key (or run a local one). Without a configured brain, it can hear and speak UI but can't answer.
- **Pointing/clicking accuracy = the model's eyesight.** Strong vision models (GPT-4o, Claude) point accurately; lighter/free models (Llama, small ones) often miss the exact pixel. The mechanics are perfect; the precision isn't guaranteed.
- **Agentic clicking depends on Accessibility being granted AND a capable model.** It can misclick; that's what **Stop** and the sensitive-step confirm are for. (This path still needs end-to-end verification on each machine.)

### Sight
- **It only sees what's rendered on screen.** It cannot read the internals of background/minimized apps, other Spaces, or content behind other windows — only what's visibly displayed.
- **It reads pixels, not app data.** It doesn't have native API access into Mail/Slack/etc. (that's the future MCP work).

### Memory
- **Recall is recent + keyword/endpoint query, not true semantic search (RAG).** No embeddings yet.
- **No memory browser UI** — you can save and recall, but not yet visually browse/edit individual memories.
- **Cloud memory needs a valid API endpoint.** If the configured URL is a webpage instead of an API, capture/recall silently no-op.

### Platform / distribution
- **Mac only.** No Windows/Linux/web — the core relies on macOS-exclusive APIs (ScreenCaptureKit, AppKit, CGEvent, AVFoundation).
- **Not yet a public download.** No signed/notarized DMG yet — that needs an Apple Developer account ($99/yr). Today it runs via Xcode / a local install.
- **Multi-monitor "screenN" mapping** has a known edge case; single-display is solid.

### Cost & privacy trade-offs
- **Every AI call costs** (your provider's pricing). **Proactive co-pilot** and **ambient capture** make periodic calls while enabled → ongoing cost; both are **off by default**.
- **Ambient/proactive watch your screen on a timer** when enabled — that's powerful but privacy-sensitive, hence opt-in with change-detection + cooldowns.

### Maturity
- Several features are **compile-verified but not exhaustively runtime-tested** on every setup; behavior (timing, coordinate precision, tour pacing) may need per-machine tuning.
- Onboarding/first-run is partly inherited from the original open-source base and is slated for a redesign.

---

## 7. Privacy model

- **Voice never leaves your Mac** (Whisper + Apple TTS are on-device).
- **Screenshots + text go only to the AI provider you configured** (your key, your account).
- **Memory notes go only to the memory endpoint you configured** (if any); local memory stays on disk.
- **No analytics, no telemetry, no third-party services.**
- **Screen capture happens only on your hotkey/button** — unless you explicitly enable proactive or ambient watching.
- Keys + personal info live in the **macOS Keychain**, never in the app bundle or any committed file.

---

## 8. Current status (what's verified vs. what needs setup)

| Area | Status |
|---|---|
| Builds + runs (signed locally) | ✅ |
| Voice → answer (with a configured key) | ✅ working |
| On-device transcription + TTS | ✅ |
| Memory save (local) | ✅ (verified, files on disk) |
| Cursor / tours / spotlight | ✅ built; accuracy = model |
| Proactive + ambient watchers | ✅ built (opt-in) |
| Agentic autofill | ✅ built; **click execution needs per-machine verification** |
| Cloud memory (GML/gigzs) | ⏳ built; **needs the correct API endpoint** |
| Public signed DMG | ⛔ not yet (needs Apple Developer cert) |

---

## 9. Requirements
- macOS 14.2 or later
- A vision-capable AI: an API key (OpenAI/Gemini/OpenRouter) **or** a local Ollama vision model
- ~150 MB one-time WhisperKit model download
- Permissions: Microphone, Accessibility, Screen Recording, Screen Content

---

## 10. Roadmap (next)
1. **My Info vault** ✅ (done) — autofill knows your data
2. **Agents / personas** — multiple specialized Nuts (coding / writing / research)
3. **Ship it** — signed + notarized DMG, drag-to-Applications, redesigned onboarding
4. **MCP integrations** — connect Notion / Slack / GitHub / Calendar as real tools
5. Semantic memory (RAG), memory browser UI, action history + undo

---

*Nut is a white-label built on the open-source [Clicky](https://github.com/farzaa/clicky) project (MIT). On-device voice, bring-your-own-key brain, memory layer, proactive + ambient capture, guided tours, and agentic automation were added on top.*
