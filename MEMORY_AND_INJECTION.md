# Nut — Memory & Injection Design Doc

> A single reference for everything we've discussed: the full feature set, the memory layer
> (capture → extract → store → recall), context injection into other AIs, the sandbox model
> that makes it possible, and the trade-offs of each choice. Illustrative code is included;
> nothing here is auto-applied to the app unless we decide to build it.

---

## 0. How the pieces relate (the big picture)

```
                        ┌─────────────────────────────────────────────┐
                        │                 NUT                    │
                        │      (menu-bar, non-sandboxed macOS app)     │
                        └─────────────────────────────────────────────┘
                                          │
         ┌────────────────────────────────┼────────────────────────────────┐
         ▼                                 ▼                                 ▼
  ┌─────────────┐                  ┌───────────────┐                ┌────────────────┐
  │  LIVE Q&A   │                  │ MEMORY LAYER  │                │   INJECTION    │
  │ talk + see  │                  │ capture →     │                │ push context   │
  │ screen →    │ ───feeds──────►  │ extract →     │ ───feeds────►  │ INTO other AIs │
  │ model →     │   context        │ store →       │   context      │ (ChatGPT, etc.)│
  │ speak+point │                  │ recall        │                │                │
  └─────────────┘                  └───────────────┘                └────────────────┘
        │                                  │                                  │
        └── on-device voice (Whisper/Apple TTS), self-hosted model (Qwen2.5-VL on GCP) ──┘
```

- **Live Q&A** is the existing product loop (push-to-talk → screenshot → model → spoken answer + cursor pointing).
- **Memory layer** captures and persists screen context so it can be recalled later.
- **Injection** takes that context (or the current screen) and hands it off to a *different* AI website to continue there.
- All three share the same plumbing: screen capture, the vision model, and (because the app is **non-sandboxed**) the ability to drive other apps.

---

## 1. Current feature set

**What it is:** a macOS menu-bar AI companion that sees your screen, talks with you, and points at things — like a tutor beside your cursor.

| Feature | Detail |
|---|---|
| 🎙️ Push-to-talk | Hold **Control+Option** anywhere (works backgrounded via a CGEvent tap) |
| 👀 Screen vision | Captures **all monitors** per ask (ScreenCaptureKit), excludes its own windows |
| 🗣️ Spoken replies | Streamed answer written "for the ear" |
| 👉 Element pointing | Blue cursor flies to UI elements via `[POINT:x,y]` tags, multi-monitor mapped |
| 🧠 Memory layer | Save screen context on command; injected into later answers (this doc) |
| 💬 Session history | Recent exchanges kept in-session |
| 🎛️ Menu-bar panel | Status, model picker (cosmetic), permissions, **Remember this screen**, feedback, quit |
| 🖼️ Cursor overlay | Waveform, response bubble, spinner, pointing animation |
| 🧭 Onboarding | Welcome → live demo → "press control+option" prompt (intro video removed) |
| 🔄 Auto-update | Sparkle; launches at login |

**Independence stack (what we changed):**
- **Speech-to-text:** on-device **WhisperKit** (no AssemblyAI)
- **Text-to-speech:** on-device **Apple AVSpeechSynthesizer** (no ElevenLabs)
- **Brain:** self-hosted **Qwen2.5-VL on GCP** via a Cloudflare Worker adapter (no Anthropic key)
- **Analytics:** removed (PostHog gone)
- **Net:** the only outbound call is to your own model endpoint.

---

## 2. The Memory Layer

Pipeline: **trigger → capture → extract → store → recall.**

### 2.1 Capture trigger — Voice/explicit vs Interval (every ~10s)

This is the biggest design fork. Two philosophies:

| | **Explicit** ("remember this" / button) | **Interval / ambient** (auto every ~10s) |
|---|---|---|
| How | User triggers a save | Timer captures the screen on a schedule |
| Signal quality | **High** — user picked what matters | Low — mostly redundant frames |
| Privacy | **Good** — only what you choose | **Severe** — records *everything* (passwords, DMs, banking). This is the "Microsoft Recall" problem |
| Storage | Tiny (a few saves/day) | **Explodes** — see math below |
| Cost/battery | Negligible | **High** — a model call every 10s, constant capture, thermal/battery drain |
| Recall power | "Things I flagged" | "Total recall" of your whole day |
| Misses things | Yes — you must remember to save | No — captures unprompted |

**The interval math (why it's heavy):**
- Every 10s = 6/min = 360/hr ≈ **2,880 captures per 8-hour day**.
- As stored images (~¼ MB each): **~720 MB/day**, ~5 GB/week.
- As model-extracted text only: storage shrinks, but you've now made **2,880 model calls/day** → real $ + latency + battery.

**Verdict: explicit (voice/button) is the right *default*.** It's private, cheap, and high-signal. Interval/ambient is powerful for "what was I doing at 3pm?" but is a privacy/cost/storage minefield.

**If you want ambient anyway, make it survivable:**
1. **Change detection** — only capture when the screen *meaningfully* changes (perceptual hash / frame diff). Kills 80–95% of redundant frames.
2. **Local pre-filter** — cheap on-device OCR/heuristics decide if a frame is worth sending to the model (skip lock screens, idle, video).
3. **App/site exclusions + a global pause** — never capture banking, password managers, incognito, a user blocklist.
4. **Retention cap** — keep N days / a size budget; auto-evict oldest.
5. **Encryption at rest** + clear consent UI.

**Recommended:** ship **explicit-first** (on by default). Offer **ambient as an opt-in "power mode"** (off by default) with all five safeguards.

### 2.2 Extraction (screenshot → text)
On save, send the screenshot to the vision model with a "summarize this screen" prompt → get 2–4 sentences of plain text. Storing **text, not pixels** is what makes the memory compact and useful as context. (Reuses `claudeAPI.analyzeImageStreaming` + `CompanionScreenCaptureUtility`.)

### 2.3 Storage — Local vs Ephemeral-screenshot + GCP

| | **Local (current)** | **Ephemeral screenshot → extract → GCP DB** |
|---|---|---|
| Screenshot | Stored on disk per memory | **Transient** — used for extraction, then dropped |
| Persisted data | JSON + image files in Application Support | Only the **extracted text**, in a GCP database |
| Local footprint | Grows ~¼ MB/save (unbounded) | ~nothing |
| Portability | Device-bound | **Centralized** — queryable, survives reinstall, shareable across clients/AIs |
| Privacy | Best (nothing leaves device) | Screen-derived **text** lives in your cloud (needs auth + encryption) |
| Infra | None | GCP DB + an authenticated API (Cloud Run/Functions) |

> Note: the screenshot already transits GCP today (the vision model is there). The ephemeral model just means you **don't persist the pixels** — only the derived text — which is a cleaner privacy posture *and* fixes unbounded local growth.

**Storage sizing (local model):** ~150–400 KB per screenshot (1280px JPEG, q0.8); text/index < 1 KB. So 1,000 memories ≈ ~250 MB. The Whisper model (~150 MB one-time) is the bigger baseline item.

**Crash / disk-full behavior:** the store uses `do/catch` + `try?` + **atomic** writes, so a full disk **does not crash** — it degrades silently (skips the screenshot or doesn't persist that save). The real flaw is *silent* failure, not a crash. Recommended add-ons: a **free-space check** (tell the user instead of failing quietly) and a **cap/eviction** so it can never grow unbounded.

### 2.4 Recall — Recent vs Semantic (RAG)

| | **Inject recent N** (current) | **Semantic retrieval (RAG)** |
|---|---|---|
| How | Add last ~8 memories to the prompt | Embed memories + query, inject only the relevant top-k |
| Build cost | Trivial, no deps | Needs an embedding model + vector store |
| Quality at scale | Degrades (dilution, token limits) | **Scales** — only relevant context |
| When to use | Tens of memories | Hundreds+ |

> You rarely want to inject *all* 100–200 memories (see §3.3 — it doesn't fit a URL and overwhelms the model anyway). **Retrieve the relevant few.**

---

## 3. Injection — continue with the same context in another AI

Goal: take context (current screen or saved memory) and drop it into a **different AI website** (ChatGPT, Claude, Perplexity, Gemini) so you continue there without re-explaining.

### 3.1 Why it's even possible: the sandbox model

macOS **App Sandbox** locks an app inside its own container — it **cannot** watch global keys, control other apps, or paste into them. **Every Mac App Store app must be sandboxed.**

| | **Sandboxed** (e.g. Bear, Things, most App Store apps) | **Non-sandboxed** (e.g. Raycast, Alfred, Rectangle, **Nut**) |
|---|---|---|
| Global hotkey | ❌ | ✅ |
| See/capture other apps | ❌ | ✅ |
| Control / **paste into** other apps | ❌ | ✅ |
| Mac App Store | ✅ | ❌ — ships via notarized **DMG** |

Nut's entitlements have **`app-sandbox = false`** + Accessibility permission (already granted for the hotkey). That combo is *exactly* what's needed to inject — and it's why it ships as a DMG, not on the App Store. **Trade-off:** users must trust it and grant Accessibility.

### 3.2 The four injection mechanisms

| Mechanism | How | Length limit | Reliability | Work |
|---|---|---|---|---|
| **A. URL prefill** | Open `site/?q=<context>` | ❌ ~2–8 KB cap | Only some sites | Trivial |
| **B. Clipboard + ⌘V** | Copy context, simulate ⌘V into focused box | ✅ none | Works **anywhere** | Small (have the perms) |
| **C. Pointer link** | Host context on GCP, inject a *short* link the AI fetches | ✅ none (link is tiny) | Needs AI with web browsing | Medium (GCP + API) |
| **D. Browser extension** | Extension fills + submits the site's box via DOM | ✅ none | **Most reliable**, per-site | Most (build/ship extension) |

**B (clipboard + ⌘V) is the universal workhorse.** A (URL) is a nice shortcut for short prompts on supported sites. C scales any length via a tiny URL but depends on the AI browsing. D is the "real" one-click-everywhere solution but is a separate project.

### 3.3 Why URL prefill is length-limited (and the math)
- Safe-everywhere URL ≈ **2,000 chars**; servers reject ≈ **8,000**; URL-encoding inflates text **1.5–3×**.
- 100–200 memories ≈ 30,000–60,000 chars → **10–60× over** the limit. **Impossible to put in a URL.**
- **Fixes:** (1) have the model produce a *short handoff* (~1,200 chars) that fits; (2) for big context, use **clipboard (B)** or a **pointer link (C)**; (3) inject the **relevant few**, not all.

### 3.4 Why `?q=` works on some sites but not others
There is **no web standard** that makes `?q=` fill a chat box — each site must *deliberately build* "read the URL param → populate the composer."

| Site | URL handoff (`?q=`) | Why | Use |
|---|---|---|---|
| **ChatGPT** | ✅ usually | Built for search/share entry points | URL path |
| **Perplexity** | ✅ reliable | It's a *search* UX (`?q=` = the query) | URL path |
| **Claude** | ⚠️ unreliable | (1) SPA likely ignores `?q=`; (2) **login redirect strips the param**; (3) undocumented → can break | Clipboard path |
| **Gemini** | ⚠️ unreliable | Same — no documented prefill contract | Clipboard path |

> Honest caveat: these are undocumented and shift over time — verify live at build time. That's exactly why the design needs a **clipboard fallback** rather than trusting every site.

### 3.5 The combined "capture here → continue there" flow

```
"continue this in chatgpt"
  → capture screen  (existing)
  → model writes a SHORT handoff (≤~1200 chars, so it fits a URL)
  → save to memory  (optional)
  → ChatGPT/Perplexity → open  site/?q=<handoff>     (URL path)
     Claude/Gemini/other → clipboard + open site + ⌘V  (clipboard path)
  → the box is prefilled → you hit Enter and continue
```

---

## 4. Code reference (illustrative)

**Inject = clipboard + a simulated ⌘V** (reuses Accessibility; works in any focused field):
```swift
func inject(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    let src = CGEventSource(stateID: .combinedSessionState)
    let v: CGKeyCode = 9 // 'v'
    let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
    down?.flags = .maskCommand
    let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
    down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
}
```

**Per-site URL (use URLComponents — it encodes correctly):**
```swift
enum AISite {
    case chatgpt, perplexity, claude
    var baseURL: URL {
        switch self {
        case .chatgpt:    return URL(string: "https://chatgpt.com/")!
        case .perplexity: return URL(string: "https://www.perplexity.ai/search")!
        case .claude:     return URL(string: "https://claude.ai/new")!
        }
    }
    var supportsURLPrefill: Bool { self == .chatgpt || self == .perplexity }
    func urlWithPrompt(_ p: String) -> URL? {
        var c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        c?.queryItems = [URLQueryItem(name: "q", value: p)]
        return c?.url
    }
}
```

**Open with length guard + clipboard fallback (the per-site router):**
```swift
func openInAI(site: AISite, context: String) {
    if site.supportsURLPrefill,
       let url = site.urlWithPrompt(context), url.absoluteString.count <= 8000 {
        NSWorkspace.shared.open(url)                 // URL path
    } else {
        inject(context)                              // (or just copy)
        NSWorkspace.shared.open(site.baseURL)        // clipboard path → user/auto ⌘V
    }
}
```

**Extraction prompt (caps length so URL works):**
```swift
static let continuationExtractionPrompt = """
write a compact context handoff so the user can continue in a different ai chat.
in UNDER 1200 characters: what they're working on, key on-screen details, and what's next.
plain text, no markdown, no pointing tags.
"""
```

**Trigger (same pattern as the memory "remember this" command):**
```swift
static func continuationTarget(in t: String) -> AISite? {
    let s = t.lowercased()
    guard s.contains("continue") || s.contains("open this in") else { return nil }
    if s.contains("chatgpt") || s.contains("gpt") { return .chatgpt }
    if s.contains("perplexity") { return .perplexity }
    if s.contains("claude") { return .claude }
    return nil
}
```

---

## 5. Pros & cons — consolidated

**Capture:** explicit = private/cheap/high-signal but misses things · interval = total recall but privacy/storage/cost heavy.
**Storage:** local = private/offline but device-bound + unbounded · GCP-ephemeral = portable/queryable/bounded-local but needs secure infra.
**Recall:** recent = simple but doesn't scale · semantic = scales but needs embeddings.
**Injection:** URL = trivial but length-limited + few sites · clipboard = universal + unlimited but pastes into focused field · pointer-link = unlimited via tiny URL but needs AI browsing · extension = most reliable but most work.
**Sandbox:** non-sandboxed = enables all of this but means DMG-only (no App Store) + requires user trust.

---

## 6. Recommended build order

1. **Injection v1** — clipboard + ⌘V into the focused AI site, no auto-send. (Smallest, robust, universal.)
2. **Handoff command** — "continue this in <site>": capture → short handoff → URL for ChatGPT/Perplexity, clipboard for the rest.
3. **Memory safeguards** — free-space check + retention cap.
4. **GCP-ephemeral storage** (if you want portability + cross-AI) — screenshots transient, text → GCP DB + authed API.
5. **Semantic retrieval** — once memories grow into the hundreds.
6. **(Optional) Ambient capture** — opt-in, with change detection + exclusions + retention + encryption.
7. **(Optional) Browser extension** — for fully automatic fill-and-send everywhere.

## 7. Open risks / decisions
- **Privacy:** memory = a record of your screens. Local + encrypted by default; explicit consent for ambient/cloud.
- **Security (if GCP):** the memory API must be authenticated + encrypted — it's sensitive.
- **ToS:** automating third-party AI sites is inherently brittle and may bump site terms.
- **Distribution:** non-sandboxed → notarized DMG only (already your model).
