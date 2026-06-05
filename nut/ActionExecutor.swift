//
//  ActionExecutor.swift
//  nut
//
//  Performs the actual mouse/keyboard input for an approved ParsedAction by
//  posting CGEvents at the system HID tap. This extends the CGEvent plumbing
//  introduced by ContextInjector (which only handles ⌘V) to the broader
//  click / type / shortcut / scroll vocabulary the model can request.
//
//  Like ContextInjector, this requires:
//      • Accessibility permission (already granted for push-to-talk)
//      • The app to be non-sandboxed (already true — see entitlements)
//
//  Coordinates in screen-space are CG coordinates (top-left origin) — the
//  caller is responsible for converting from screenshot-pixel space first.
//

import AppKit
import CoreGraphics
import Foundation

@MainActor
enum ActionExecutor {

    /// Performs `action`. `screenSpaceLocation` (CG coords, top-left origin) is
    /// only used by the CLICK case — TYPE/KEYS/SCROLL target whatever's focused.
    static func perform(_ action: ParsedAction, screenSpaceLocation: CGPoint? = nil) {
        switch action {
        case let .click(_, _, label):
            guard let screenSpaceLocation else {
                print("⚠️ ActionExecutor: CLICK requested but no screen-space location was supplied")
                return
            }
            performLeftClick(at: screenSpaceLocation)
            print("🖱️ Action executed: CLICK \(label) at \(screenSpaceLocation)")

        case let .type(text, label):
            performType(text: text)
            print("⌨️ Action executed: TYPE (\(text.count) chars) into \(label.isEmpty ? "focused field" : label)")

        case let .keys(combo, label):
            performKeyboardCombo(combo)
            print("⌨️ Action executed: KEYS \(combo) — \(label)")

        case let .scroll(direction, amount, label):
            performScroll(direction: direction, lines: amount)
            print("📜 Action executed: SCROLL \(direction.rawValue) \(amount) in \(label.isEmpty ? "focused area" : label)")
        }
    }

    // MARK: - Click

    private static func performLeftClick(at screenSpaceLocation: CGPoint) {
        guard let eventSource = CGEventSource(stateID: .combinedSessionState) else { return }

        // First move the cursor visibly to the click target so the user can
        // see where the click is landing — both for trust and for apps that
        // only register clicks at the actual cursor position.
        if let mouseMove = CGEvent(mouseEventSource: eventSource,
                                   mouseType: .mouseMoved,
                                   mouseCursorPosition: screenSpaceLocation,
                                   mouseButton: .left) {
            mouseMove.post(tap: .cghidEventTap)
        }

        // Tiny pause so the OS registers the move before the click; otherwise
        // some apps see a click at the previous cursor location.
        usleep(20_000)

        if let mouseDown = CGEvent(mouseEventSource: eventSource,
                                   mouseType: .leftMouseDown,
                                   mouseCursorPosition: screenSpaceLocation,
                                   mouseButton: .left) {
            mouseDown.post(tap: .cghidEventTap)
        }

        if let mouseUp = CGEvent(mouseEventSource: eventSource,
                                 mouseType: .leftMouseUp,
                                 mouseCursorPosition: screenSpaceLocation,
                                 mouseButton: .left) {
            mouseUp.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Type

    /// Types `text` into whatever's focused by posting one keystroke per
    /// character using the Unicode-string path on CGEvent. This sidesteps
    /// per-character keyCode lookups and handles unicode/emoji correctly.
    private static func performType(text: String) {
        guard let eventSource = CGEventSource(stateID: .combinedSessionState) else { return }

        for character in text {
            // CGEvent expects UTF-16 code units. Use unsafe-pointer overload so
            // multi-code-unit characters (emoji, etc.) work.
            let utf16CodeUnits = Array(String(character).utf16)
            guard let keyDownEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true) else { continue }
            keyDownEvent.keyboardSetUnicodeString(stringLength: utf16CodeUnits.count, unicodeString: utf16CodeUnits)
            keyDownEvent.post(tap: .cghidEventTap)

            guard let keyUpEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false) else { continue }
            keyUpEvent.keyboardSetUnicodeString(stringLength: utf16CodeUnits.count, unicodeString: utf16CodeUnits)
            keyUpEvent.post(tap: .cghidEventTap)

            // Small inter-key pause so receiving apps don't drop fast keystrokes.
            usleep(8_000)
        }
    }

    // MARK: - Keyboard combo

    /// Parses combos like "cmd+s", "cmd+shift+t", "option+space" and posts the
    /// chord as a single keyDown/keyUp pair with the appropriate flags.
    private static func performKeyboardCombo(_ combo: String) {
        let parts = combo.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty else { return }

        var modifierFlags: CGEventFlags = []
        var primaryKeyName: String?

        for part in parts {
            switch part {
            case "cmd", "command", "meta": modifierFlags.insert(.maskCommand)
            case "ctrl", "control":        modifierFlags.insert(.maskControl)
            case "opt", "option", "alt":   modifierFlags.insert(.maskAlternate)
            case "shift":                  modifierFlags.insert(.maskShift)
            case "fn":                     modifierFlags.insert(.maskSecondaryFn)
            default:                       primaryKeyName = part
            }
        }

        guard let primaryKeyName, let primaryKeyCode = virtualKeyCode(forKeyName: primaryKeyName) else {
            print("⚠️ ActionExecutor: unknown key in combo \"\(combo)\"")
            return
        }

        guard let eventSource = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: primaryKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: eventSource, virtualKey: primaryKeyCode, keyDown: false) else { return }

        keyDown.flags = modifierFlags
        keyUp.flags = modifierFlags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    /// Single-character/named-key → virtual key code map. Covers the common
    /// editing keys + letters a-z and digits 0-9. ANSI US layout (sufficient
    /// for ⌘-shortcuts which are layout-independent for letters on macOS).
    private static func virtualKeyCode(forKeyName keyName: String) -> CGKeyCode? {
        switch keyName {
        case "a": return 0;  case "s": return 1;  case "d": return 2;  case "f": return 3
        case "h": return 4;  case "g": return 5;  case "z": return 6;  case "x": return 7
        case "c": return 8;  case "v": return 9;  case "b": return 11; case "q": return 12
        case "w": return 13; case "e": return 14; case "r": return 15; case "y": return 16
        case "t": return 17; case "1": return 18; case "2": return 19; case "3": return 20
        case "4": return 21; case "6": return 22; case "5": return 23; case "9": return 25
        case "7": return 26; case "8": return 28; case "0": return 29; case "o": return 31
        case "u": return 32; case "i": return 34; case "p": return 35; case "l": return 37
        case "j": return 38; case "k": return 40; case "n": return 45; case "m": return 46
        case "return", "enter":        return 36
        case "tab":                    return 48
        case "space":                  return 49
        case "delete", "backspace":    return 51
        case "escape", "esc":          return 53
        case "left", "arrowleft":      return 123
        case "right", "arrowright":    return 124
        case "down", "arrowdown":      return 125
        case "up", "arrowup":          return 126
        default:                       return nil
        }
    }

    // MARK: - Scroll

    private static func performScroll(direction: ParsedAction.ScrollDirection, lines: Int) {
        // CGEvent scrolls in "lines"; the sign convention is positive-up.
        // X/Y axes are independent; we use Y for up/down, X for left/right.
        var yLines: Int32 = 0
        var xLines: Int32 = 0
        switch direction {
        case .up:    yLines =  Int32(lines)
        case .down:  yLines = -Int32(lines)
        case .right: xLines = -Int32(lines)
        case .left:  xLines =  Int32(lines)
        }

        guard let scrollEvent = CGEvent(scrollWheelEvent2Source: nil,
                                        units: .line,
                                        wheelCount: 2,
                                        wheel1: yLines,
                                        wheel2: xLines,
                                        wheel3: 0) else { return }
        scrollEvent.post(tap: .cghidEventTap)
    }
}
