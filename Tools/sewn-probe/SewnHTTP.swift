//
//  SewnHTTP.swift
//  sewn-probe
//
//  WHAT: Sewn's wire, spoken directly: sign-in, the stack secret header, JSON calls and
//        the chat SSE stream.
//

import Foundation

struct SewnHTTP {
    let base: URL
    var token: String?
    var secret: String?

    func request(_ path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 900
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let secret { request.setValue(secret, forHTTPHeaderField: "X-Ambient-Secret") }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    func data(_ path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request(path, method: method, body: body))
        try Self.check(response, data: data, path: path)
        return data
    }

    struct SignIn: Decodable {
        let accessToken: String
        let userId: String
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case userId = "user_id"
        }
    }

    func signIn(email: String, password: String) async throws -> SignIn {
        let body = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        return try JSONDecoder().decode(SignIn.self, from: await data("v1/auth/sign-in", method: "POST", body: body))
    }

    /// The `data:` payloads of an SSE response, until `[DONE]`.
    func events(_ path: String, body: Data) async throws -> AsyncThrowingStream<String, Error> {
        var request = request(path, method: "POST", body: body)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var text = ""
            for try await line in bytes.lines { text += line }
            throw ProbeError.http(http.statusCode, path, text)
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" { break }
                        continuation.yield(payload)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func check(_ response: URLResponse, data: Data, path: String) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw ProbeError.http(http.statusCode, path, String(data: data, encoding: .utf8) ?? "")
        }
    }
}

enum ProbeError: Error, CustomStringConvertible {
    case http(Int, String, String)
    case missing(String)

    var description: String {
        switch self {
        case .http(let status, let path, let body): return "HTTP \(status) from /\(path): \(body)"
        case .missing(let what): return what
        }
    }
}
