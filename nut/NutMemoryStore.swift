//
//  NutMemoryStore.swift
//  nut
//
//  Local, on-device "memory layer". When the user explicitly asks to remember
//  the screen, we persist a compact record — a model-written summary, the
//  user's note, a timestamp, and the screenshot — to Application Support. Recent
//  memories are later injected into the model's context so Nut can recall
//  what it was shown. Nothing leaves the machine.
//

import Foundation

/// One saved screen memory.
struct ScreenMemory: Codable, Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    /// What the user said when saving (the voice note), if any.
    let userNote: String
    /// Model-generated description of what was on screen at save time.
    let screenSummary: String
    /// File name of the saved screenshot inside the store's `screenshots/` dir.
    let screenshotFileName: String?
}

/// Actor-isolated so all disk I/O happens off the main thread and concurrent
/// saves/reads can't corrupt the index.
actor NutMemoryStore {
    static let shared = NutMemoryStore()

    private let directoryURL: URL
    private let indexFileURL: URL
    private let screenshotsDirectoryURL: URL

    private var memories: [ScreenMemory] = []
    private var hasLoadedFromDisk = false

    init() {
        let applicationSupportURL = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory

        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.nut.app"
        directoryURL = applicationSupportURL
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
        indexFileURL = directoryURL.appendingPathComponent("memories.json")
        screenshotsDirectoryURL = directoryURL.appendingPathComponent("screenshots", isDirectory: true)
    }

    // MARK: - Public API

    func count() -> Int {
        loadIfNeeded()
        return memories.count
    }

    /// Most recent memories first.
    func recentMemories(limit: Int) -> [ScreenMemory] {
        loadIfNeeded()
        return Array(memories.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }

    func allMemories() -> [ScreenMemory] {
        loadIfNeeded()
        return memories.sorted { $0.createdAt > $1.createdAt }
    }

    /// Persists a new memory (writing the screenshot to disk) and returns it.
    @discardableResult
    func saveMemory(userNote: String, screenSummary: String, screenshotImageData: Data?) -> ScreenMemory {
        loadIfNeeded()

        let memoryID = UUID()
        var screenshotFileName: String?
        if let screenshotImageData {
            let fileName = "\(memoryID.uuidString).jpg"
            let fileURL = screenshotsDirectoryURL.appendingPathComponent(fileName)
            do {
                try screenshotImageData.write(to: fileURL, options: .atomic)
                screenshotFileName = fileName
            } catch {
                print("⚠️ MemoryStore: failed to write screenshot: \(error)")
            }
        }

        let memory = ScreenMemory(
            id: memoryID,
            createdAt: Date(),
            userNote: userNote,
            screenSummary: screenSummary,
            screenshotFileName: screenshotFileName
        )
        memories.append(memory)
        persistIndex()
        return memory
    }

    func deleteMemory(id: UUID) {
        loadIfNeeded()
        if let memory = memories.first(where: { $0.id == id }),
           let screenshotFileName = memory.screenshotFileName {
            try? FileManager.default.removeItem(
                at: screenshotsDirectoryURL.appendingPathComponent(screenshotFileName)
            )
        }
        memories.removeAll { $0.id == id }
        persistIndex()
    }

    func clearAll() {
        loadIfNeeded()
        try? FileManager.default.removeItem(at: screenshotsDirectoryURL)
        try? FileManager.default.createDirectory(at: screenshotsDirectoryURL, withIntermediateDirectories: true)
        memories.removeAll()
        persistIndex()
    }

    // MARK: - Disk

    private func loadIfNeeded() {
        guard !hasLoadedFromDisk else { return }
        hasLoadedFromDisk = true

        try? FileManager.default.createDirectory(at: screenshotsDirectoryURL, withIntermediateDirectories: true)

        guard let indexData = try? Data(contentsOf: indexFileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([ScreenMemory].self, from: indexData) {
            memories = decoded
        }
    }

    private func persistIndex() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let indexData = try? encoder.encode(memories) else { return }
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? indexData.write(to: indexFileURL, options: .atomic)
    }
}
