//
//  ContextInjector.swift
//  nut
//
//  Puts text into other apps via the clipboard + a simulated ⌘V keystroke.
//  This is the foundation under both "send context to another AI website" (the
//  Feature B build) and the future "click/type/control other apps" agent mode
//  (Feature A) — both reuse the CGEvent-posting plumbing here.
//
//  Requires Accessibility permission (already granted for the push-to-talk
//  hotkey) and that the app is non-sandboxed (already true — see entitlements).
//

import AppKit
import Foundation

@MainActor
enum ContextInjector {

    // MARK: - Clipboard

    /// Replaces the system clipboard contents with `text`.
    static func setClipboard(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Paste

    /// Copies `text` to the clipboard and simulates ⌘V into whatever field is
    /// currently focused. This works in any app because the keystroke is posted
    /// at the HID-event-tap level — the receiving app just sees a real ⌘V.
    /// Returns immediately; playback happens asynchronously.
    static func pasteIntoFocused(text: String) {
        setClipboard(text: text)
        postCommandV()
    }

    /// Opens the given URL in the default browser, then (after a small load delay
    /// so the page's text field has time to become first responder) posts ⌘V to
    /// paste `text` into it. Used for sites that don't support URL prefill — we
    /// open the bare site and inject the prompt into its composer.
    static func openURLAndPaste(siteURL: URL, text: String, loadDelaySeconds: Double = 1.6) {
        setClipboard(text: text)
        NSWorkspace.shared.open(siteURL)
        // Wait for the browser tab + composer to be focusable before pasting.
        // 1.6s is a heuristic — fast for already-open browsers, generous enough
        // for cold launches. Tunable per-site if we see paste landing too early.
        DispatchQueue.main.asyncAfter(deadline: .now() + loadDelaySeconds) {
            postCommandV()
        }
    }

    // MARK: - CGEvent plumbing

    /// Posts a ⌘V keystroke at the system HID tap so it lands in whatever
    /// application is frontmost. Silently no-ops on failure (e.g. if
    /// Accessibility permission was revoked at runtime).
    private static func postCommandV() {
        // 'V' on a US ANSI layout. macOS keyboards using non-Latin layouts still
        // map ⌘V via this virtual key code — the keystroke is interpreted as the
        // *physical* key, which is the same paste key on any layout.
        let virtualKeyForV: CGKeyCode = 9

        guard let eventSource = CGEventSource(stateID: .combinedSessionState),
              let keyDownEvent = CGEvent(keyboardEventSource: eventSource,
                                         virtualKey: virtualKeyForV,
                                         keyDown: true),
              let keyUpEvent = CGEvent(keyboardEventSource: eventSource,
                                       virtualKey: virtualKeyForV,
                                       keyDown: false) else {
            print("⚠️ ContextInjector: failed to build ⌘V CGEvent")
            return
        }

        keyDownEvent.flags = .maskCommand
        keyUpEvent.flags = .maskCommand
        keyDownEvent.post(tap: .cghidEventTap)
        keyUpEvent.post(tap: .cghidEventTap)
    }
}
