//
//  GMLMemoryClient.swift
//  nut
//
//  REST client for the GML (Graph Memory Layer) memory orchestration service
//  that powers akhrots.com. Nut pushes each conversation turn / screen context
//  to GML so it becomes durable, searchable memory, and queries GML for
//  relevant memories to inject into the AI's context on later turns.
//
//  The live API (verified against the running service):
//    • POST {base}/api/memory/ingest   {user_query, assistant_reply}
//    • POST {base}/api/memory/recall   {query, top_k, rerank, expand} -> {results:[{memory, score, why}]}
//    • auth: Authorization: Bearer <per-user api key>
//  where {base} is the public origin (e.g. https://akhrots.com).
//
//  Config is stored in UserDefaults (base URL) + Keychain (api key) via
//  GMLSettings. On first launch Nut imports a bundled `akhort-config.json`
//  (shipped in the per-user download zip) so the user is signed in silently —
//  nothing to paste. If GML is not configured, all calls silently no-op and
//  Nut falls back to the local NutMemoryStore.
//

import Combine
import Foundation

// MARK: - Settings

/// Persists the GML base URL + per-user API key. Base URL goes in UserDefaults
/// (not secret); the API key goes in the Keychain.
@MainActor
final class GMLSettings: ObservableObject {
    static let shared = GMLSettings()

    /// The public API origin, e.g. "https://akhrots.com". Nut appends the
    /// "/api/memory/..." paths to this.
    @Published private(set) var endpoint: String
    @Published private(set) var authToken: String

    private static let endpointKey  = "gmlEndpoint"
    private static let bundledConfigImportedKey = "gmlBundledConfigImported"
    private static let keychainService = "com.nut.gml"
    private static let keychainAccount = "gmlAuthToken"

    private init() {
        self.endpoint  = UserDefaults.standard.string(forKey: Self.endpointKey) ?? ""
        self.authToken = KeychainHelper.read(service: Self.keychainService,
                                              account: Self.keychainAccount) ?? ""
    }

    /// True once we have both a base URL and an API key to authenticate with.
    var isConfigured: Bool {
        !endpoint.trimmingCharacters(in: .whitespaces).isEmpty &&
        !authToken.trimmingCharacters(in: .whitespaces).isEmpty
    }

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

    // MARK: - Bundled "silent sign-in" config (Gap 2)

    /// On first launch, look for the `akhort-config.json` that ships next to the
    /// app in the per-user download zip, import the API key + origin from it, and
    /// delete the file. This is what lets a downloaded copy of Nut be signed in
    /// to the user's akhrots.com account with nothing to paste.
    ///
    /// The server bakes `{"token": "<api key>", "url": "https://akhrots.com/mcp"}`.
    /// We derive the REST origin from that url's scheme + host.
    func importBundledConfigIfPresent() {
        guard !UserDefaults.standard.bool(forKey: Self.bundledConfigImportedKey) else { return }

        let fileManager = FileManager.default
        var candidateConfigURLs: [URL] = []
        // 1. ~/Downloads — the canonical location (matches the Windows bootstrap,
        //    which reads %USERPROFILE%\Downloads\akhort-config.json).
        if let downloadsDirectory = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            candidateConfigURLs.append(downloadsDirectory.appendingPathComponent("akhort-config.json"))
        }
        // 2. Next to the running app bundle (if launched straight from the unzip folder).
        let appContainingDirectory = Bundle.main.bundleURL.deletingLastPathComponent()
        candidateConfigURLs.append(appContainingDirectory.appendingPathComponent("akhort-config.json"))
        // 3. Home directory (last-ditch).
        candidateConfigURLs.append(fileManager.homeDirectoryForCurrentUser.appendingPathComponent("akhort-config.json"))

        for configURL in candidateConfigURLs {
            guard fileManager.fileExists(atPath: configURL.path) else { continue }
            guard let configData = try? Data(contentsOf: configURL),
                  let configObject = try? JSONSerialization.jsonObject(with: configData) as? [String: Any],
                  let token = (configObject["token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty else {
                // The file is there but unreadable / malformed — say so instead of
                // silently leaving the user unsigned-in and wondering why.
                print("⚠️ GML: found \(configURL.lastPathComponent) but it's malformed or missing a 'token' — skipping silent sign-in")
                continue
            }

            let restOrigin = Self.deriveRestOrigin(fromConfigURL: configObject["url"] as? String ?? "")
            update(endpoint: restOrigin, authToken: token)

            // The download README promises Nut removes the config after reading it,
            // so the per-user key isn't left lying around on disk.
            try? fileManager.removeItem(at: configURL)
            UserDefaults.standard.set(true, forKey: Self.bundledConfigImportedKey)
            print("🧠 GML: imported bundled sign-in config → \(restOrigin)")
            return
        }
    }

    /// The config carries the MCP endpoint url (e.g. https://akhrots.com/mcp);
    /// the REST API lives at the same origin, so we keep scheme + host (+ port)
    /// and drop the path. An `mcp.` host prefix is normalized to the apex.
    private static func deriveRestOrigin(fromConfigURL configURLString: String) -> String {
        guard let components = URLComponents(string: configURLString),
              let scheme = components.scheme,
              var host = components.host else {
            return "https://akhrots.com"  // production default
        }
        if host.hasPrefix("mcp.") {
            host = String(host.dropFirst("mcp.".count))
        }
        if let port = components.port {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }
}

// MARK: - Request shapes

/// Body for POST /api/memory/ingest — GML models memory as conversation turns.
private struct GMLIngestRequest: Encodable {
    let userQuery: String
    let assistantReply: String
    enum CodingKeys: String, CodingKey {
        case userQuery = "user_query"
        case assistantReply = "assistant_reply"
    }
}

// MARK: - Client

/// Thin async wrapper around the GML REST API.
/// All methods silently no-op when GML is not configured.
actor GMLMemoryClient {
    static let shared = GMLMemoryClient()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest  = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    private let encoder = JSONEncoder()

    /// Builds an authenticated POST request to a GML API path, or nil if GML
    /// isn't configured / the URL is malformed.
    private func makeRequest(path: String, base: String, authToken: String) -> URLRequest? {
        let trimmedBase = base.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: "\(trimmedBase)\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !authToken.isEmpty {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    // MARK: - Ingest

    /// Sends one conversation turn (what the user asked + what Nut answered, or a
    /// screen-context summary) to GML for durable storage. GML's pipeline
    /// classifies, embeds, and stores it server-side. Silently skips if GML is
    /// not configured.
    func ingest(userQuery: String, assistantReply: String) async {
        let settings = await GMLSettings.shared
        guard await settings.isConfigured else {
            print("🧠 GML: not configured, skipping ingest")
            return
        }
        let base = await settings.endpoint
        let authToken = await settings.authToken

        guard var request = makeRequest(path: "/api/memory/ingest", base: base, authToken: authToken) else {
            print("⚠️ GML: invalid base URL for ingest: \(base)")
            return
        }

        do {
            request.httpBody = try encoder.encode(
                GMLIngestRequest(userQuery: userQuery, assistantReply: assistantReply)
            )
            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            if (200...299).contains(statusCode) {
                print("🧠 GML: ingested turn (\(assistantReply.count) chars)")
            } else if statusCode == 401 {
                print("🚨 GML: ingest unauthorized (401) — the API key may be revoked. Re-download Nut from akhrots.com.")
            } else {
                let bodyText = String(data: data, encoding: .utf8) ?? ""
                print("⚠️ GML: ingest failed \(statusCode): \(bodyText.prefix(180))")
            }
        } catch {
            print("⚠️ GML: ingest error: \(error)")
        }
    }

    // MARK: - Recall

    /// Queries GML for memories relevant to the user's current question. Returns
    /// up to `limit` memories as formatted strings ready to inject into the AI
    /// system prompt. Returns [] if GML isn't configured or the query fails —
    /// the caller always falls back to local memory.
    func query(transcript: String, limit: Int = 5) async -> [String] {
        let settings = await GMLSettings.shared
        guard await settings.isConfigured else { return [] }
        let base = await settings.endpoint
        let authToken = await settings.authToken

        guard var request = makeRequest(path: "/api/memory/recall", base: base, authToken: authToken) else {
            return []
        }

        // {query, top_k, rerank, expand} — rerank+expand give the best matches.
        let body: [String: Any] = [
            "query": transcript,
            "top_k": limit,
            "rerank": true,
            "expand": true
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200...299).contains(statusCode) else {
                if statusCode == 401 {
                    print("🚨 GML: recall unauthorized (401) — the API key may be revoked. Re-download Nut from akhrots.com. Falling back to local memory.")
                } else {
                    print("⚠️ GML: recall failed with status \(statusCode)")
                }
                return []
            }

            // Response: {query, results:[{memory:{content,timestamp,...}, score, why}]}.
            // Parsed defensively so a schema tweak can't silently drop everything.
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else {
                return []
            }

            let formattedMemories = results.compactMap { result -> String? in
                let memory = result["memory"] as? [String: Any]
                let content = (memory?["content"] as? String)
                    ?? (memory?["value"] as? String)
                    ?? (memory?["summary_short"] as? String)
                guard let content, !content.isEmpty else { return nil }
                let timestamp = memory?["timestamp"] as? String ?? ""
                let timePart = timestamp.isEmpty ? "" : " [\(timestamp)]"
                return "-\(timePart) \(content)"
            }

            print("🧠 GML: recalled \(formattedMemories.count) relevant memories")
            return formattedMemories
        } catch {
            print("⚠️ GML: recall error: \(error)")
            return []
        }
    }
}
