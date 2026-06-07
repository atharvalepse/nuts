//
//  DirectVisionLLMClient.swift
//  nut
//
//  Calls an OpenAI-compatible chat-completions endpoint DIRECTLY from the app —
//  no Cloudflare Worker, no localhost bridge. This is what lets a downloaded copy
//  of Nut work with the user's own key (BYOK): they configure provider/endpoint/
//  key/model in LLMSettings, and this client talks straight to it.
//
//  It exposes the SAME interface as ClaudeAPI (`analyzeImageStreaming` /
//  `analyzeImage`) so CompanionManager's pipeline didn't have to change — the only
//  difference is the wire format is OpenAI (image_url data URIs + `choices[].delta`
//  SSE) instead of Anthropic.
//

import Foundation

final class DirectVisionLLMClient {
    private let endpointURL: URL
    private let apiKey: String
    var model: String
    private let session: URLSession

    init(endpoint: String, apiKey: String, model: String) {
        // Fall back to OpenAI if the configured endpoint is somehow unparseable,
        // so we never crash on a malformed settings string.
        self.endpointURL = URL(string: endpoint)
            ?? URL(string: "https://api.openai.com/v1/chat/completions")!
        self.apiKey = apiKey
        self.model = model

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)
    }

    // MARK: - Request building

    private func makeRequest() -> URLRequest {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Local providers like Ollama need no key; only send the header when set.
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// Screen captures are JPEG; pasted images may be PNG. Declare the right
    /// data-URI MIME so strict providers don't reject the image.
    private func detectImageMediaType(for imageData: Data) -> String {
        if imageData.count >= 4 {
            let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            if [UInt8](imageData.prefix(4)) == pngSignature {
                return "image/png"
            }
        }
        return "image/jpeg"
    }

    /// Builds the OpenAI `messages` array: a system message, prior turns, then the
    /// current turn with each labeled screenshot as an `image_url` data URI.
    private func buildMessages(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String
    ) -> [[String: Any]] {
        var messages: [[String: Any]] = []

        messages.append(["role": "system", "content": systemPrompt])

        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        var contentBlocks: [[String: Any]] = []
        for image in images {
            contentBlocks.append([
                "type": "text",
                "text": image.label
            ])
            let mediaType = detectImageMediaType(for: image.data)
            contentBlocks.append([
                "type": "image_url",
                "image_url": [
                    "url": "data:\(mediaType);base64,\(image.data.base64EncodedString())"
                ]
            ])
        }
        contentBlocks.append([
            "type": "text",
            "text": userPrompt
        ])
        messages.append(["role": "user", "content": contentBlocks])

        return messages
    }

    // MARK: - Streaming

    /// Streaming vision request. Mirrors ClaudeAPI.analyzeImageStreaming's signature
    /// and behavior (calls `onTextChunk` with the accumulated text), but parses the
    /// OpenAI SSE shape: `data: {choices:[{delta:{content}}]}`.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        var request = makeRequest()
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "stream": true,
            "messages": buildMessages(
                images: images,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                userPrompt: userPrompt
            )
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (byteStream, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "DirectVisionLLMClient",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"]
            )
        }

        // On a non-2xx, drain the body so we can surface the provider's real error
        // (e.g. "insufficient_quota", "no endpoints", "invalid api key").
        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBodyChunks: [String] = []
            for try await line in byteStream.lines {
                errorBodyChunks.append(line)
            }
            let errorBody = errorBodyChunks.joined(separator: "\n")
            throw NSError(
                domain: "DirectVisionLLMClient",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "API Error (\(httpResponse.statusCode)): \(errorBody)"]
            )
        }

        var accumulatedResponseText = ""

        for try await line in byteStream.lines {
            // OpenAI-style SSE lines look like: "data: {json}" (sometimes "data:{json}").
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty { continue }
            if payload == "[DONE]" { break }

            guard let payloadData = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let delta = firstChoice["delta"] as? [String: Any],
                  let textChunk = delta["content"] as? String,
                  !textChunk.isEmpty else {
                continue
            }

            accumulatedResponseText += textChunk
            let currentAccumulatedText = accumulatedResponseText
            await onTextChunk(currentAccumulatedText)
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: accumulatedResponseText, duration: duration)
    }

    // MARK: - Non-streaming

    /// Non-streaming variant, kept for parity with ClaudeAPI. Parses
    /// `choices[0].message.content`.
    func analyzeImage(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        var request = makeRequest()
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "messages": buildMessages(
                images: images,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                userPrompt: userPrompt
            )
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let responseString = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "DirectVisionLLMClient",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "API Error: \(responseString)"]
            )
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choices = json?["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw NSError(
                domain: "DirectVisionLLMClient",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid response format"]
            )
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: text, duration: duration)
    }
}
