//
//  GMLMemoryClient.swift
//  nut
//
//  REST client for the GML (Graph Memory Layer) running on Google Cloud.
//  Sends screen context to GML when the user says "remember this" or clicks
//  the Remember button. Also queries GML for relevant memories to inject
//  into the AI's context on each conversation turn.
//
//  Config is stored in UserDefaults (endpoint) and Keychain (auth token) via
//  GMLSettings — the user fills these in the Nut panel Settings screen.
//  If GML is not configured, all calls are silently skipped and Nut falls
//  back to the local NutMemoryStore.
//

import Combine
import Foundation

// MARK: - Settings

/// Persists the GML endpoint + auth token. Endpoint goes in UserDefaults
/// (not secret); token goes in the Keychain.
@MainActor
final class GMLSettings: ObservableObject {
    static let shared = GMLSettings()

    @Published private(set) var endpoint: String
    @Published private(set) var authToken: String

    private static let endpointKey  = "gmlEndpoint"
    private static let keychainService = "com.nut.gml"
    private static let keychainAccount = "gmlAuthToken"

    private init() {
        self.endpoint  = UserDefaults.standard.string(forKey: Self.endpointKey) ?? ""
        self.authToken = KeychainHelper.read(service: Self.keychainService,
                                              account: Self.keychainAccount) ?? ""
    }

    /// True once the user has entered a base URL.
    var isConfigured: Bool { !endpoint.trimmingCharacters(in: .whitespaces).isEmpty }

    func update(endpoint: String, authToken: String) {
        let trimmedEndpoint  = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken     = authToken.trimmingCharacters(in: .whitespacesAndNewlines)

        self.endpoint  = trimmedEndpoint
        self.authToken = trimmedToken

        UserDefaults.standard.set(trimmedEndpoint, forKey: Self.endpointKey)

        if trimmedToken.isEmpty {
            KeychainHelper.delete(service: Self.keychainService, account: Self.keychainAccount)
        } else {
            KeychainHelper.save(trimmedToken, service: Self.keychainService,
                                account: Self.keychainAccount)
        }
    }
}

// MARK: - Request / Response shapes

/// The body Nut sends to GML when ingesting a new memory.
private struct GMLIngestRequest: Encodable {
    /// The raw text content of the memory (screen summary + optional user note).
    let content: String
    /// Structured metadata so GML can tag/filter by source app and timestamp.
    let metadata: GMLMetadata
}

private struct GMLMetadata: Encodable {
    let source: String      // always "nut"
    let timestamp: String   // ISO-8601
    let userNote: String    // the note the user spoke alongside "remember this"
}

/// The body Nut sends to GML when querying for relevant memories.
private struct GMLQueryRequest: Encodable {
    let query: String       // the user's current question / transcript
    let limit: Int          // max memories to return (default 5)
}

/// One memory returned by the GML query endpoint.
struct GMLMemory: Decodable {
    let id: String
    let content: String
    let metadata: [String: String]?
    let score: Double?      // relevance score when returned by semantic search
}

private struct GMLQueryResponse: Decodable {
    let memories: [GMLMemory]
}

// MARK: - Client

/// Thin async wrapper around the GML REST API.
/// All methods silently no-op when GML is not configured (endpoint is empty).
actor GMLMemoryClient {
    static let shared = GMLMemoryClient()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest  = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - Ingest

    /// Sends a screen memory to GML for durable storage.
    /// Called from CompanionManager after the model has written the screen summary.
    /// Silently skips if GML is not configured.
    func ingest(screenSummary: String, userNote: String) async {
        let settings = await GMLSettings.shared
        guard await settings.isConfigured else {
            print("🧠 GML: not configured, skipping ingest")
            return
        }

        let endpoint = await settings.endpoint
        let authToken = await settings.authToken

        let base = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/ingest") else {
            print("⚠️ GML: invalid endpoint URL: \(base)/ingest")
            return
        }

        let isoDate = ISO8601DateFormatter().string(from: Date())
        let body = GMLIngestRequest(
            content: userNote.isEmpty ? screenSummary : "\(userNote)\n\n\(screenSummary)",
            metadata: GMLMetadata(source: "nut", timestamp: isoDate, userNote: userNote)
        )

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !authToken.isEmpty {
                request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = try encoder.encode(body)

            let (_, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1

            if (200...299).contains(statusCode) {
                print("🧠 GML: ingested memory (\(screenSummary.count) chars)")
            } else {
                print("⚠️ GML: ingest failed with status \(statusCode)")
            }
        } catch {
            print("⚠️ GML: ingest error: \(error)")
        }
    }

    // MARK: - Query

    /// Queries GML for memories relevant to the user's current question.
    /// Returns up to `limit` memories as formatted strings ready to inject
    /// into the AI system prompt. Returns empty array if GML is not configured
    /// or the query fails — the caller always falls back to local memory.
    func query(transcript: String, limit: Int = 5) async -> [String] {
        let settings = await GMLSettings.shared
        guard await settings.isConfigured else { return [] }

        let endpoint = await settings.endpoint
        let authToken = await settings.authToken

        let base = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/query") else { return [] }

        let body = GMLQueryRequest(query: transcript, limit: limit)

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !authToken.isEmpty {
                request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = try encoder.encode(body)

            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1

            guard (200...299).contains(statusCode) else {
                print("⚠️ GML: query failed with status \(statusCode)")
                return []
            }

            let queryResponse = try decoder.decode(GMLQueryResponse.self, from: data)
            let formattedMemories = queryResponse.memories.map { memory -> String in
                let note = memory.metadata?["userNote"] ?? ""
                let timestamp = memory.metadata?["timestamp"] ?? ""
                let notePart = note.isEmpty ? "" : " (user said: \"\(note)\")"
                let timePart = timestamp.isEmpty ? "" : " [\(timestamp)]"
                return "-\(timePart)\(notePart) \(memory.content)"
            }

            print("🧠 GML: retrieved \(formattedMemories.count) relevant memories")
            return formattedMemories
        } catch {
            print("⚠️ GML: query error: \(error)")
            return []
        }
    }
}
