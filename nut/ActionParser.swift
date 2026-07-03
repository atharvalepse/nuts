//
//  ActionParser.swift
//  nut
//
//  Parses an "action tag" out of the model's response — the same pattern as
//  the existing [POINT:x,y:label] tag, extended to executable actions:
//
//      [CLICK:x,y:label]                — left-click at the screenshot-space pixel (x,y)
//      [TYPE:"some text":label]         — type literal text into the focused field
//      [KEYS:cmd+shift+s:label]         — send a keyboard shortcut
//      [SCROLL:direction:amount:label]  — direction = up|down|left|right, amount = lines
//
//  ONE action per response. If the response contains both a [POINT] and an
//  action, the action wins (parsePointingCoordinates is called first elsewhere;
//  the action parser strips its own tag from the spoken text).
//

import Foundation

enum ParsedAction: Equatable {
    case click(x: Double, y: Double, label: String)
    case type(text: String, label: String)
    case keys(combo: String, label: String)
    case scroll(direction: ScrollDirection, amount: Int, label: String)
    case openApp(appName: String, label: String)
    case drag(fromX: Double, fromY: Double, toX: Double, toY: Double, label: String)

    enum ScrollDirection: String { case up, down, left, right }

    /// Short human-readable description shown in the consent prompt.
    var humanDescription: String {
        switch self {
        case let .click(_, _, label):           return "Click \(label)"
        case let .type(text, label):
            // Show the first ~40 chars of the typed text so the user knows what's going in.
            let preview = text.count > 40 ? String(text.prefix(40)) + "…" : text
            return "Type \"\(preview)\"" + (label.isEmpty ? "" : " into \(label)")
        case let .keys(combo, label):
            return "Send " + combo + (label.isEmpty ? "" : " — \(label)")
        case let .scroll(direction, amount, label):
            return "Scroll \(direction.rawValue) \(amount) line\(amount == 1 ? "" : "s")" + (label.isEmpty ? "" : " in \(label)")
        case let .openApp(appName, _):
            return "Open \(appName)"
        case let .drag(_, _, _, _, label):
            return "Drag \(label)"
        }
    }
}

struct ActionParseResult: Equatable {
    /// The response text with the action tag stripped out, ready to speak.
    let spokenText: String
    /// The parsed action, if the response contained one.
    let action: ParsedAction?
}

enum ActionParser {

    /// Scans the response for one action tag (CLICK/TYPE/KEYS/SCROLL) and
    /// returns the cleaned spoken text plus the parsed action (if any). Tags
    /// are case-insensitive on the action name; arguments are case-sensitive
    /// (so typed text preserves its casing).
    static func parse(_ responseText: String) -> ActionParseResult {
        // Match the whole tag — non-greedy capture inside the brackets so we
        // stop at the first ']' that isn't preceded by an escape.
        let pattern = #"\[(CLICK|TYPE|KEYS|SCROLL|OPEN|DRAG):([^\]]+)\]"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return ActionParseResult(spokenText: responseText, action: nil)
        }

        let fullRange = NSRange(responseText.startIndex..., in: responseText)
        guard let match = regex.firstMatch(in: responseText, options: [], range: fullRange),
              match.numberOfRanges >= 3,
              let actionNameRange = Range(match.range(at: 1), in: responseText),
              let actionArgsRange = Range(match.range(at: 2), in: responseText),
              let fullTagRange = Range(match.range, in: responseText) else {
            return ActionParseResult(spokenText: responseText, action: nil)
        }

        let actionName = responseText[actionNameRange].uppercased()
        let actionArgs = String(responseText[actionArgsRange])

        let parsedAction = parseActionArgs(actionName: actionName, actionArgs: actionArgs)

        // Strip the tag from the spoken text; collapse any whitespace it left behind.
        var spokenText = responseText
        spokenText.removeSubrange(fullTagRange)
        spokenText = spokenText
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return ActionParseResult(spokenText: spokenText, action: parsedAction)
    }

    // MARK: - Per-action arg parsing

    private static func parseActionArgs(actionName: String, actionArgs: String) -> ParsedAction? {
        switch actionName {
        case "CLICK":  return parseClickArgs(actionArgs)
        case "TYPE":   return parseTypeArgs(actionArgs)
        case "KEYS":   return parseKeysArgs(actionArgs)
        case "SCROLL": return parseScrollArgs(actionArgs)
        case "OPEN":   return parseOpenArgs(actionArgs)
        case "DRAG":   return parseDragArgs(actionArgs)
        default:       return nil
        }
    }

    /// `x,y:label` or `x,y`
    private static func parseClickArgs(_ args: String) -> ParsedAction? {
        let parts = args.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let coordinatesPart = parts[0].trimmingCharacters(in: .whitespaces)
        let label = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""

        let coordinates = coordinatesPart.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard coordinates.count == 2,
              let x = Double(coordinates[0]),
              let y = Double(coordinates[1]) else { return nil }

        return .click(x: x, y: y, label: label.isEmpty ? "the target" : label)
    }

    /// `"text":label` or `"text"`. The text is the substring between the
    /// first and last double-quote characters so embedded `:` inside the
    /// typed text don't confuse the parser.
    private static func parseTypeArgs(_ args: String) -> ParsedAction? {
        guard let firstQuote = args.firstIndex(of: "\""),
              let lastQuote = args.lastIndex(of: "\""),
              firstQuote < lastQuote else { return nil }

        let textStart = args.index(after: firstQuote)
        let typedText = String(args[textStart..<lastQuote])

        // Anything after the closing quote, if it starts with `:`, is the label.
        let afterClosingQuote = args[args.index(after: lastQuote)...]
        let label: String
        if let colon = afterClosingQuote.firstIndex(of: ":") {
            label = String(afterClosingQuote[afterClosingQuote.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
        } else {
            label = ""
        }

        return .type(text: typedText, label: label)
    }

    /// `cmd+s:label` or `cmd+shift+t`. The combo is preserved verbatim for the
    /// executor to interpret; the parser just splits off the label.
    private static func parseKeysArgs(_ args: String) -> ParsedAction? {
        let parts = args.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let combo = parts[0].trimmingCharacters(in: .whitespaces)
        let label = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        guard !combo.isEmpty else { return nil }
        return .keys(combo: combo, label: label)
    }

    /// `direction:amount:label` (label optional). Direction is up/down/left/right.
    private static func parseScrollArgs(_ args: String) -> ParsedAction? {
        let parts = args.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2,
              let direction = ParsedAction.ScrollDirection(rawValue: parts[0].trimmingCharacters(in: .whitespaces).lowercased()),
              let amount = Int(parts[1].trimmingCharacters(in: .whitespaces)),
              amount > 0 else { return nil }
        let label = parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespaces) : ""
        return .scroll(direction: direction, amount: amount, label: label)
    }

    /// `AppName` or `AppName:label`. Launches an app by its display name.
    private static func parseOpenArgs(_ args: String) -> ParsedAction? {
        let parts = args.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let appName = parts[0].trimmingCharacters(in: .whitespaces)
        guard !appName.isEmpty else { return nil }
        let label = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        return .openApp(appName: appName, label: label)
    }

    /// `x1,y1:x2,y2:label` or `x1,y1:x2,y2` — drag from the first point to the second.
    private static func parseDragArgs(_ args: String) -> ParsedAction? {
        let parts = args.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return nil }
        let from = parts[0].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let to = parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard from.count == 2, to.count == 2,
              let fromX = Double(from[0]), let fromY = Double(from[1]),
              let toX = Double(to[0]), let toY = Double(to[1]) else { return nil }
        let label = parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespaces) : ""
        return .drag(fromX: fromX, fromY: fromY, toX: toX, toY: toY, label: label.isEmpty ? "the item" : label)
    }
}
