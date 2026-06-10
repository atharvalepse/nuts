//
//  ContextJournalStore.swift
//  nut
//
//  The local half of Nut's "living memory": a lightweight, append-only journal
//  of ambient context captures — {timestamp, app, activity, intent, entities,
//  summary} — stored as JSON-lines in Application Support. Text only (no
//  screenshots), so it can hold weeks of context in a few hundred kilobytes.
//
//  Ambient capture ALWAYS writes here, and ALSO syncs to the GML cloud layer
//  when one is configured — so the living memory keeps working even when the
//  cloud endpoint is missing or down (previously those captures were lost).
//
//  Like NutMemoryStore, this is an actor so all file I/O is serialized off the
//  main thread.
//

import Foundation

struct ContextJournalEntry: Codable {
    let timestamp: Date
    let appName: String
    let activity: String
    let intent: String
    let entities: [String]
    let summary: String
}

actor ContextJournalStore {
    static let shared = ContextJournalStore()

    private let journalFileURL: URL
    private let jsonEncoder: JSONEncoder
    private let jsonDecoder: JSONDecoder

    /// Keep roughly this many entries; once the file exceeds the trim threshold
    /// it is rewritten down to the cap (oldest entries dropped).
    private let maxJournalEntries = 2000
    private let trimThresholdEntries = 2400

    private init() {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.atharvalepse.nut"
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let contextDirectoryURL = applicationSupportURL
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("context", isDirectory: true)
        try? FileManager.default.createDirectory(at: contextDirectoryURL, withIntermediateDirectories: true)
        journalFileURL = contextDirectoryURL.appendingPathComponent("journal.jsonl")

        jsonEncoder = JSONEncoder()
        jsonEncoder.dateEncodingStrategy = .iso8601
        jsonDecoder = JSONDecoder()
        jsonDecoder.dateDecodingStrategy = .iso8601
    }

    /// Appends one entry as a JSON line. Trims the file when it grows past the
    /// threshold so the journal never grows unbounded.
    func append(_ entry: ContextJournalEntry) {
        guard var encodedLine = try? jsonEncoder.encode(entry) else { return }
        encodedLine.append(contentsOf: [0x0A])  // newline

        if let fileHandle = try? FileHandle(forWritingTo: journalFileURL) {
            fileHandle.seekToEndOfFile()
            fileHandle.write(encodedLine)
            try? fileHandle.close()
        } else {
            try? encodedLine.write(to: journalFileURL)
        }

        trimIfNeeded()
    }

    /// The most recent `limit` entries, newest first. Returns [] on any read error.
    func recentEntries(limit: Int) -> [ContextJournalEntry] {
        allEntries().suffix(limit).reversed()
    }

    /// Total entries currently in the journal (for the panel / debugging).
    func count() -> Int {
        allEntries().count
    }

    // MARK: - Private

    private func allEntries() -> [ContextJournalEntry] {
        guard let fileContents = try? String(contentsOf: journalFileURL, encoding: .utf8) else { return [] }
        return fileContents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                guard let lineData = line.data(using: .utf8) else { return nil }
                return try? jsonDecoder.decode(ContextJournalEntry.self, from: lineData)
            }
    }

    private func trimIfNeeded() {
        let entries = allEntries()
        guard entries.count > trimThresholdEntries else { return }
        let trimmedEntries = Array(entries.suffix(maxJournalEntries))
        let trimmedLines = trimmedEntries.compactMap { entry -> String? in
            guard let encodedEntry = try? jsonEncoder.encode(entry) else { return nil }
            return String(data: encodedEntry, encoding: .utf8)
        }
        let rewrittenContents = trimmedLines.joined(separator: "\n") + "\n"
        try? rewrittenContents.write(to: journalFileURL, atomically: true, encoding: .utf8)
    }
}
