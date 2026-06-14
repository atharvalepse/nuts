# Nut — Production Launch Plan

**Honest status today:** Nut is a *working alpha on your Mac*. It is **not yet installable by strangers** — the build is signed with a development certificate (device-locked, not notarized), so it won't open on anyone else's machine. The brain also broke today because config + key were fragile. Production = closing those gaps. None of this is huge individually; it's about doing the unglamorous shipping work.

Legend: **[YOU]** = only you can do it · **[ME]** = I can do it · **[BOTH]** = I drive, you provide a credential/decision.

---

## 🚧 The 3 hard blockers (cannot launch without these)

### 1. Apple distribution — so the download actually opens
- **[YOU]** Enroll in the **Apple Developer Program** ($99/yr). This is the gate for everything below.
- **[YOU]** Create a **"Developer ID Application"** certificate (you currently only have "Apple Development" certs).
- **[BOTH]** Run `xcrun notarytool store-credentials` once (stores your Apple creds in *your* keychain — nothing in chat).
- **[ME]** Re-sign Nut with Developer ID + hardened runtime → **notarize** → **staple** → package DMG.
- **[YOU]** Host the `.dmg` on akhrots.com behind the "Download Nuts for Mac" button.
- **[ME, later]** Auto-update (re-add Sparkle) so you can ship fixes without users re-downloading.

### 2. The brain at scale — decide BYOK vs hosted (see decision below)
- Today it's **BYOK** (each user pastes their own API key). That's why it broke — and your own screenshot says *"nothing to paste."* Those conflict. Pick one before launch.

### 3. Reliability — it must not silently die or break on bad config
- **[ME]** Make a missing/bad brain config show a clear in-app error instead of failing silently (today it pointed at `https://localhost` and just didn't work).
- **[ME]** Wire **crash + error reporting** (NutAnalytics is currently a no-op) so you can *see* failures in the field. Recommend Sentry (free tier) — ~1 hr.
- **[ME]** Add a model fallback (if Gemini 503s past retries, fall back to a second model) so a provider blip ≠ dead app.

---

## 🔑 The one strategic decision: BYOK vs Hosted brain

| | **BYOK** (each user brings a key) | **Hosted brain** (you run it) |
|---|---|---|
| User experience | ❌ "Go get a Gemini key" → huge drop-off | ✅ Download → works (your screenshot's vision) |
| Your cost | ✅ $0 — users pay their own AI | ❌ You pay for everyone's inference |
| Work to ship | ✅ Low (already built) | ❌ Worker + auth + rate-limit + accounts |
| Abuse risk | ✅ None | ⚠️ Must protect the proxy or people drain it |

**My recommendation:** ship **v1 as notarized BYOK to a small early-access list** (fastest path to real feedback), and build the **hosted brain for v2** (the frictionless public launch). Don't block v1 on the hosted infra.

If you want hosted from day one, the work is: deploy the Worker pointed at Gemini, hold the key as a Cloudflare secret, add per-user auth tokens issued by akhrots.com sign-in, rate-limit, and bundle only the Worker URL (no key) in the app.

---

## ✅ Full checklist by workstream

### Distribution
- [ ] [YOU] Apple Developer Program enrollment
- [ ] [YOU] Developer ID Application cert created + installed
- [ ] [ME] `notarize.sh`: sign (hardened runtime) → notarize → staple → DMG → sign DMG
- [ ] [YOU] Host versioned `.dmg` + a stable URL
- [ ] [ME] Auto-update (Sparkle) + appcast feed

### Brain
- [ ] [YOU] Decide BYOK vs hosted
- [ ] [ME] (hosted) Deploy Worker + secret + auth + rate-limit
- [ ] [ME] Model fallback + clear error surfacing
- [ ] [BOTH] Rotate every API key pasted in chat this session (treat as public)

### Reliability
- [ ] [ME] Crash/error telemetry (Sentry)
- [ ] [ME] Graceful handling of missing key / bad endpoint (no silent death)
- [ ] [ME] "Brain not configured" onboarding state instead of a dead app

### Onboarding & first-run
- [ ] [ME] Guided permissions flow (Screen Recording, Mic, Accessibility) with retry
- [ ] [ME] First-run: key entry (BYOK) or sign-in (hosted)
- [ ] [ME] Redesign the inherited-from-Clicky onboarding screens

### Legal / privacy (mandatory — it watches the screen)
- [ ] [BOTH] **Privacy policy** (what's captured, what's sent where, opt-ins) — I draft, you/your lawyer review
- [ ] [BOTH] **Terms of service**
- [ ] [ME] In-app privacy disclosure on first launch + before enabling ambient/proactive
- [x] [ME] Sensitive-data redaction (done this session)
- [x] [ME] Clicky/MIT attribution (kept)

### Ops & growth
- [ ] [ME] In-app "Report a problem" → email/issue
- [ ] [ME] Versioning + release notes
- [ ] [YOU] Landing page polish + download analytics

---

## 🎯 Recommended v1 scope (ship in ~1–2 weeks)
A **notarized, BYOK, early-access** build:
1. Developer ID + notarized DMG ✅ opens on any Mac
2. Crash reporting ✅ you see failures
3. Guided onboarding (permissions + paste key) ✅ users get running
4. Privacy policy + in-app disclosure ✅ legally safe
5. Graceful errors ✅ no silent death

Then **v2:** hosted brain + akhrots.com accounts = the "download and it just works" public launch.

---

## ▶️ The next 3 actions
1. **[YOU]** Enroll in Apple Developer Program — *nothing ships without this; start it today.*
2. **[YOU]** Tell me: **BYOK or hosted** for v1.
3. **[ME, now, no blockers]** I can immediately start on: crash reporting + graceful-error handling + the notarize script (ready for the moment your cert lands). Say go.
