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
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
enum ActionExecutor {

    /// Appends a diagnostic line to /tmp/nut_actions.log so we can see whether
    /// actions are firing and whether Accessibility (required to post synthetic
    /// events) is actually granted to the running app.
    private static func logToFile(_ message: String) {
        let line = "\(Date()): \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: "/tmp/nut_actions.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    /// Whether Accessibility is granted. Posting clicks/keystrokes silently
    /// no-ops without it, so callers can warn the user instead of failing quietly.
    static var hasAccessibilityForActions: Bool { AXIsProcessTrusted() }

    /// Performs `action`. `screenSpaceLocation` (CG coords, top-left origin) is
    /// only used by the CLICK case — TYPE/KEYS/SCROLL target whatever's focused.
    static func perform(_ action: ParsedAction, screenSpaceLocation: CGPoint? = nil, secondScreenSpaceLocation: CGPoint? = nil) {
        let accessibilityTrusted = AXIsProcessTrusted()
        // Never write typed content to the log file — during autofill it can be a
        // password or card number, and the log lives in world-readable /tmp. Log
        // only the character count for TYPE actions.
        let logSafeDescription: String
        if case let .type(text, label) = action {
            logSafeDescription = "Type [\(text.count) chars hidden]" + (label.isEmpty ? "" : " into \(label)")
        } else {
            logSafeDescription = action.humanDescription
        }
        logToFile("perform: \(logSafeDescription) | accessibilityTrusted=\(accessibilityTrusted) | loc=\(screenSpaceLocation.map { "(\(Int($0.x)),\(Int($0.y)))" } ?? "nil")")
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

        case let .openApp(appName, _):
            performOpenApp(named: appName)
            print("🚀 Action executed: OPEN \(appName)")

        case let .drag(_, _, _, _, label):
            guard let dragStart = screenSpaceLocation, let dragEnd = secondScreenSpaceLocation else {
                print("⚠️ ActionExecutor: DRAG needs both screen-space points")
                return
            }
            performDrag(from: dragStart, to: dragEnd)
            print("🫳 Action executed: DRAG \(label)")
        }
    }

    // MARK: - Click

    private static func performLeftClick(at screenSpaceLocation: CGPoint) {
        guard let eventSource = CGEventSource(stateID: .combinedSessionState) else { return }

        // Glide the cursor to the target STEP BY STEP so the movement is smooth and
        // visible (the mascot follows the real cursor), instead of teleporting.
        moveCursorSmoothly(to: screenSpaceLocation, source: eventSource)

        // Tiny pause so the OS registers the final move before the click; otherwise
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

    /// Moves the cursor from its current position to `target` over several small
    /// steps with an ease-in-out curve, so the on-screen movement is smooth and
    /// visible (a human-like glide) rather than an instant teleport.
    private static func moveCursorSmoothly(to target: CGPoint, source: CGEventSource) {
        let start = CGEvent(source: nil)?.location ?? target
        let distance = hypot(target.x - start.x, target.y - start.y)
        // Scale step count with distance so short hops are quick and long travels
        // glide dramatically across the screen.
        let steps = max(12, min(70, Int(distance / 14)))
        guard steps > 1 else { return }
        for step in 1...steps {
            let progress = CGFloat(step) / CGFloat(steps)
            // ease-in-out cubic for a natural accelerate/decelerate feel
            let eased = progress < 0.5
                ? 4 * progress * progress * progress
                : 1 - pow(-2 * progress + 2, 3) / 2
            let x = start.x + (target.x - start.x) * eased
            let y = start.y + (target.y - start.y) * eased
            if let move = CGEvent(mouseEventSource: source,
                                  mouseType: .mouseMoved,
                                  mouseCursorPosition: CGPoint(x: x, y: y),
                                  mouseButton: .left) {
                move.post(tap: .cghidEventTap)
            }
            usleep(11_000)   // slower, more visible glide across the screen
        }
    }

    // MARK: - Drag

    /// Drag-and-drop: glide to `from`, press, drag STEP BY STEP to `to` while
    /// holding the button (so the movement is fully visible), then release.
    private static func performDrag(from start: CGPoint, to end: CGPoint) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        moveCursorSmoothly(to: start, source: source)
        usleep(40_000)
        if let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                              mouseCursorPosition: start, mouseButton: .left) {
            down.post(tap: .cghidEventTap)
        }
        usleep(50_000)
        let steps = 36
        for step in 1...steps {
            let progress = CGFloat(step) / CGFloat(steps)
            let eased = progress < 0.5 ? 2 * progress * progress : 1 - pow(-2 * progress + 2, 2) / 2
            let x = start.x + (end.x - start.x) * eased
            let y = start.y + (end.y - start.y) * eased
            if let drag = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged,
                                  mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left) {
                drag.post(tap: .cghidEventTap)
            }
            usleep(13_000)
        }
        usleep(50_000)
        if let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                            mouseCursorPosition: end, mouseButton: .left) {
            up.post(tap: .cghidEventTap)
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

    // MARK: - Open app

    /// Launches an app by display name via `/usr/bin/open -a`. This doesn't need
    /// Accessibility (it's a launch, not synthetic input) and resolves the app
    /// name the same way Spotlight/Finder do.
    private static func performOpenApp(named appName: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", appName]
        do { try process.run() } catch { print("⚠️ ActionExecutor: failed to open \(appName): \(error)") }
    }
}
