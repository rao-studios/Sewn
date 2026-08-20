import Foundation

// MARK: - Graph mutation + policy endpoints

struct GraphMutationResponse: Codable {
    let success: Bool
    let survivingId: String?
    let entityCount: Int?

    enum CodingKeys: String, CodingKey {
        case success
        case survivingId = "surviving_id"
        case entityCount = "entity_count"
    }
}

/// Mirror of Totem's `ExtractionPolicy` (snake_case wire format).
struct ExtractionPolicyModel: Codable {
    struct KindDef: Codable, Identifiable, Hashable {
        var name: String
        var description: String
        var id: String { name }
    }

    struct CoMentionRule: Codable {
        var enabled: Bool
        var predicate: String
        var skipExplicitlyLinked: Bool

        enum CodingKeys: String, CodingKey {
            case enabled, predicate
            case skipExplicitlyLinked = "skipExplicitlyLinked"
        }
    }

    struct SimilarityRule: Codable {
        var enabled: Bool
        var cosineThreshold: Double
        var maxEdgesPerEntity: Int
        var predicate: String

        enum CodingKeys: String, CodingKey {
            case enabled
            case cosineThreshold = "cosine_threshold"
            case maxEdgesPerEntity = "max_edges_per_entity"
            case predicate
        }
    }

    var kinds: [KindDef]
    var promptTemplate: String?
    var predicateAliases: [String: String]
    var maxEntities: Int
    var maxRelationships: Int
    var coMention: CoMentionRule?
    var similarity: SimilarityRule?
    var hubDegreeCap: Int?

    enum CodingKeys: String, CodingKey {
        case kinds
        case promptTemplate = "prompt_template"
        case predicateAliases = "predicate_aliases"
        case maxEntities = "max_entities"
        case maxRelationships = "max_relationships"
        case coMention = "co_mention"
        case similarity
        case hubDegreeCap = "hub_degree_cap"
    }
}

extension TotemAPI {

    @discardableResult
    func renameEntity(id: String, name: String) async throws -> GraphMutationResponse {
        try await post("/v1/graph/entity/rename", body: ["id": id, "name": name])
    }

    @discardableResult
    func mergeEntities(from: String, into: String) async throws -> GraphMutationResponse {
        try await post("/v1/graph/entity/merge", body: ["from": from, "into": into])
    }

    @discardableResult
    func deleteEntity(id: String) async throws -> GraphMutationResponse {
        try await post("/v1/graph/entity/delete", body: ["id": id])
    }

    @discardableResult
    func setEntityKind(id: String, kind: String) async throws -> GraphMutationResponse {
        try await post("/v1/graph/entity/set-kind", body: ["id": id, "kind": kind])
    }

    @discardableResult
    func deleteRelationship(id: String) async throws -> GraphMutationResponse {
        try await post("/v1/graph/relationship/delete", body: ["id": id])
    }

    @discardableResult
    func reExtract(documentId: String, ownerId: String) async throws -> GraphMutationResponse {
        try await post("/v1/graph/re-extract", body: [
            "document_id": documentId,
            "totem": ["owner_id": ownerId],
        ])
    }

    func policy() async throws -> ExtractionPolicyModel {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/graph/policy"))
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.invalidResponse
        }
        return try JSONDecoder().decode(ExtractionPolicyModel.self, from: data)
    }

    @discardableResult
    func updatePolicy(_ policy: ExtractionPolicyModel) async throws -> ExtractionPolicyModel {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/graph/policy"))
        request.httpMethod = "PUT"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(policy)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.http((response as? HTTPURLResponse)?.statusCode ?? 0,
                                String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(ExtractionPolicyModel.self, from: data)
    }
}
