import Foundation

/// Direct REST client for a single Thread node (no auth — Thread trusts its LAN).
actor ThreadAPI {
    let baseURL: URL

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    enum APIError: LocalizedError {
        case http(Int, String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .http(let code, let body): return "HTTP \(code): \(body.prefix(300))"
            case .invalidResponse: return "Invalid response."
            }
        }
    }

    // MARK: - Graph

    func graph(ownerId: String, entity: String?, query: String?, kinds: [String] = [],
               hops: Int = 1, limit: Int = 30, includeDocuments: Bool = true) async throws -> GraphQueryResponse {
        var body: [String: Any] = [
            "thread": ["owner_id": ownerId],
            "hops": hops,
            "limit": limit,
            "include_documents": includeDocuments,
        ]
        if !kinds.isEmpty { body["kinds"] = kinds }
        if let entity, !entity.isEmpty { body["entity"] = entity }
        if let query, !query.isEmpty { body["query"] = query }
        return try await post("/v1/graph", body: body)
    }

    func search(ownerId: String, query: String, scope: String = "personal") async throws -> SearchResponseBody {
        try await post("/v1/search", body: [
            "query": query,
            "thread": ["owner_id": ownerId, "scope": scope],
        ])
    }

    struct ClearResult: Codable {
        let cleared: Bool
        let documents: Int
        let entities: Int
    }

    /// Destructive: wipes the node's partition table, graph, and registry.
    func clearDatabase() async throws -> ClearResult {
        try await post("/v1/clear", body: ["confirm": true])
    }

    // MARK: - Plumbing

    func post<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        var url = baseURL
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
