import Foundation

/// REST + SSE client for the Seer server. Auth tokens live in the Keychain;
/// requests retry once after a token refresh on 401.
actor SeerAPI {
    enum APIError: LocalizedError {
        case http(Int, String)
        case notSignedIn
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .http(let code, let body): return "HTTP \(code): \(body.prefix(300))"
            case .notSignedIn: return "Sign in required."
            case .invalidResponse: return "Invalid response."
            }
        }
    }

    private let baseURL: @Sendable () -> URL
    private var accessToken: String? = KeychainStore.get("access_token")
    private var refreshToken: String? = KeychainStore.get("refresh_token")
    private(set) var userId: String? = KeychainStore.get("user_id")

    init(baseURL: @escaping @Sendable () -> URL) {
        self.baseURL = baseURL
    }

    var isSignedIn: Bool { accessToken != nil }

    // MARK: - Auth

    func signIn(email: String, password: String) async throws {
        let response: SignInResponse = try await post(
            "/v1/auth/sign-in",
            body: ["email": email, "password": password],
            authenticated: false
        )
        store(response)
        UserDefaults.standard.set(email, forKey: "seer.client.email")
    }

    func refresh() async throws {
        guard let refreshToken else { throw APIError.notSignedIn }
        let response: SignInResponse = try await post(
            "/v1/auth/refresh",
            body: ["refresh_token": refreshToken],
            authenticated: false
        )
        store(response)
    }

    func signOut() async {
        accessToken = nil
        refreshToken = nil
        userId = nil
        KeychainStore.delete("access_token")
        KeychainStore.delete("refresh_token")
        KeychainStore.delete("user_id")
        UserDefaults.standard.removeObject(forKey: "seer.client.email")
    }

    private func store(_ response: SignInResponse) {
        accessToken = response.accessToken
        refreshToken = response.refreshToken
        userId = response.userId
        KeychainStore.set(response.accessToken, for: "access_token")
        KeychainStore.set(response.refreshToken, for: "refresh_token")
        KeychainStore.set(response.userId, for: "user_id")
    }

    // MARK: - Endpoints

    func totems() async throws -> TotemNodesResponse {
        try await get("/v1/totems", authenticated: false)
    }

    func graph(entity: String?, query: String?, kinds: [String] = [],
               hops: Int = 1, limit: Int = 30, includeDocuments: Bool = true) async throws -> GraphQueryResponse {
        var body: [String: Any] = [
            "seer": ["owner_id": userId ?? ""],
            "kinds": kinds,
            "hops": hops,
            "limit": limit,
            "include_documents": includeDocuments,
        ]
        if let entity { body["entity"] = entity }
        if let query { body["query"] = query }
        return try await post("/v1/graph", body: body)
    }

    func search(query: String, totemIds: [String] = []) async throws -> SearchResponseBody {
        var seer: [String: Any] = ["owner_id": userId ?? ""]
        if !totemIds.isEmpty { seer["totem_ids"] = totemIds }
        return try await post("/v1/search", body: ["query": query, "seer": seer])
    }

    func adminModel() async throws -> AdminModelResponse {
        try await get("/v1/admin/model")
    }

    @discardableResult
    func setAdminModel(chatModel: String?, utilityModel: String? = nil) async throws -> AdminModelResponse {
        var body: [String: Any] = [:]
        if let chatModel { body["chat_model"] = chatModel }
        if let utilityModel { body["utility_model"] = utilityModel }
        return try await request("/v1/admin/model", method: "PUT", body: body)
    }

    /// Raw JSON export of the owner's Sinatra state (`/v1/frank/export`) —
    /// consumed by the Lab's DPO pair builder.
    func frankExport() async throws -> Data {
        try await rawPost("/v1/frank/export", body: ["seer": ["owner_id": userId ?? ""]])
    }

    // MARK: - Ingest

    /// Ingests documents through Seer's `/v1/embeddings` — the production path:
    /// Seer chunks and enqueues, then relays to the targeted storage totem over
    /// its Conduit gRPC session (`personal_totem_id` picks the node; nil lets
    /// Seer choose any totem accepting storage).
    @discardableResult
    func ingest(
        texts: [String],
        names: [String],
        groupId: String,
        personalTotemId: String? = nil
    ) async throws -> Bool {
        var seer: [String: Any] = ["owner_id": userId ?? ""]
        if let personalTotemId { seer["personal_totem_id"] = personalTotemId }
        if !groupId.isEmpty {
            seer["group"] = ["id": groupId, "label": groupId.capitalized,
                             "owner_id": userId ?? "", "documents": []]
        }
        struct IngestResponse: Codable { let success: Bool? }
        let response: IngestResponse = try await post("/v1/embeddings", body: [
            "inputs": texts,
            "sanitize": true,
            "names": names,
            "seer": seer,
        ])
        return response.success ?? true
    }

    // MARK: - Personalities

    func personalities() async throws -> [Personality] {
        let response: PersonalitiesResponse = try await get("/v1/personalities")
        return response.personalities
    }

    /// Replaces the server's persona list (admin).
    @discardableResult
    func updatePersonalities(_ personalities: [Personality]) async throws -> [Personality] {
        let payload = try JSONEncoder().encode(PersonalitiesResponse(personalities: personalities))
        let body = try JSONSerialization.jsonObject(with: payload) as? [String: Any] ?? [:]
        let response: PersonalitiesResponse = try await request(
            "/v1/admin/personalities", method: "PUT", body: body
        )
        return response.personalities
    }

    // MARK: - Chat streaming

    /// Streams a chat completion, emitting references (first chunk), text deltas,
    /// the final span-annotated contribution, then `.done`.
    func chatStream(
        messages: [[String: String]],
        model: String? = nil,
        personality: String? = nil,
        personalTotemId: String? = nil,
        totemIds: [String] = []
    ) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        guard let accessToken else { throw APIError.notSignedIn }

        var seer: [String: Any] = ["owner_id": userId ?? ""]
        if let personalTotemId { seer["personal_totem_id"] = personalTotemId }
        if !totemIds.isEmpty { seer["totem_ids"] = totemIds }

        var body: [String: Any] = [
            "messages": messages,
            "stream": true,
            "max_tokens": 1024,
            "seer": seer,
        ]
        if let model { body["model"] = model }
        if let personality { body["personality"] = personality }

        var request = URLRequest(url: baseURL().appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 300

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                        var bodyText = ""
                        for try await line in bytes.lines { bodyText += line }
                        throw APIError.http(http.statusCode, bodyText)
                    }
                    let decoder = JSONDecoder()
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))
                        if payload == "[DONE]" {
                            continuation.yield(.done)
                            break
                        }
                        guard let data = payload.data(using: .utf8),
                              let chunk = try? decoder.decode(ChatChunk.self, from: data) else { continue }
                        if let references = chunk.references, !references.isEmpty {
                            continuation.yield(.references(references))
                        }
                        if let personality = chunk.personality {
                            continuation.yield(.personality(personality))
                        }
                        if let content = chunk.choices?.first?.delta?.content, !content.isEmpty {
                            continuation.yield(.delta(content))
                        }
                        if let contribution = chunk.contribution {
                            continuation.yield(.contribution(contribution))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Plumbing

    private func get<T: Decodable>(_ path: String, authenticated: Bool = true) async throws -> T {
        try await request(path, method: "GET", body: nil, authenticated: authenticated)
    }

    private func post<T: Decodable>(_ path: String, body: [String: Any], authenticated: Bool = true) async throws -> T {
        try await request(path, method: "POST", body: body, authenticated: authenticated)
    }

    private func rawPost(_ path: String, body: [String: Any]) async throws -> Data {
        let (data, _) = try await execute(path, method: "POST", body: body, authenticated: true, retried: false)
        return data
    }

    private func request<T: Decodable>(
        _ path: String, method: String, body: [String: Any]?,
        authenticated: Bool = true
    ) async throws -> T {
        let (data, _) = try await execute(path, method: method, body: body,
                                          authenticated: authenticated, retried: false)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.invalidResponse
        }
    }

    private func execute(
        _ path: String, method: String, body: [String: Any]?,
        authenticated: Bool, retried: Bool
    ) async throws -> (Data, HTTPURLResponse) {
        var url = baseURL()
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated {
            guard let accessToken else { throw APIError.notSignedIn }
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }

        if http.statusCode == 401, authenticated, !retried, refreshToken != nil {
            try await refresh()
            return try await execute(path, method: method, body: body,
                                     authenticated: authenticated, retried: true)
        }
        guard (200...299).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return (data, http)
    }
}
