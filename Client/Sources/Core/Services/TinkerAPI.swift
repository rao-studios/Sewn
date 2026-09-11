import Foundation

/// Direct Swift client for Tinker's Anthropic-compatible Messages API — used by
/// the Lab's test chat to sample base models and `tinker://…` checkpoints
/// (sampling works even while a run is still training).
actor TinkerAPI {
    static let base = URL(string: "https://tinker.thinkingmachines.dev/services/tinker-prod/anthropic/api")!

    let apiKey: String

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    enum APIError: LocalizedError {
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .http(let code, let body): return "HTTP \(code): \(body.prefix(300))"
            }
        }
    }

    /// Streams `/v1/messages` text deltas.
    func stream(
        model: String,
        system: String? = nil,
        messages: [[String: String]],
        maxTokens: Int = 1024
    ) -> AsyncThrowingStream<String, Error> {
        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "max_tokens": maxTokens,
            "stream": true,
        ]
        if let system { body["system"] = system }

        var request = URLRequest(url: Self.base.appendingPathComponent("v1/messages"))
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                        var errorBody = ""
                        for try await line in bytes.lines { errorBody += line }
                        throw APIError.http(http.statusCode, errorBody)
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        guard let data = payload.data(using: .utf8),
                              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = object["type"] as? String else { continue }
                        switch type {
                        case "content_block_delta":
                            if let delta = object["delta"] as? [String: Any],
                               let text = delta["text"] as? String {
                                continuation.yield(text)
                            }
                        case "message_stop":
                            continuation.finish()
                            return
                        case "error":
                            let message = (object["error"] as? [String: Any])?["message"] as? String
                            throw APIError.http(0, message ?? payload)
                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
