import Foundation

// Codable mirrors of the Sewn server's wire types (field names match the
// server's snake_case JSON exactly).

// MARK: - Auth

struct SignInResponse: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int?
    let userId: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case userId = "user_id"
    }
}

// MARK: - Threads

struct ThreadNodesResponse: Codable {
    let mothershipId: String?
    let totalDocumentCount: Int?
    let totalGroupCount: Int?
    let nodes: [ThreadNodeEntry]
    let enabled: Bool?

    enum CodingKeys: String, CodingKey {
        case mothershipId = "mothership_id"
        case totalDocumentCount = "total_document_count"
        case totalGroupCount = "total_group_count"
        case nodes
        case enabled
    }
}

struct ThreadNodeEntry: Codable, Identifiable, Hashable {
    let threadId: String
    let host: String
    let grpcPort: Int
    let httpPort: Int
    let isActive: Bool
    let acceptingStorage: Bool
    let stats: ThreadNodeStats?

    var id: String { threadId }

    enum CodingKeys: String, CodingKey {
        case threadId = "thread_id"
        case host
        case grpcPort = "grpc_port"
        case httpPort = "http_port"
        case isActive = "is_active"
        case acceptingStorage = "accepting_storage"
        case stats
    }
}

struct ThreadNodeStats: Codable, Hashable {
    let documentCount: Int
    let groupCount: Int
    let ownerCount: Int
    let availableDocumentCount: Int

    enum CodingKeys: String, CodingKey {
        case documentCount = "document_count"
        case groupCount = "group_count"
        case ownerCount = "owner_count"
        case availableDocumentCount = "available_document_count"
    }
}

// MARK: - Chat

struct ChatReference: Codable, Identifiable, Hashable {
    let id: String            // document id
    let partitionId: String?
    let ownerId: String?
    let threadId: String?

    enum CodingKeys: String, CodingKey {
        case id
        case partitionId = "partition_id"
        case ownerId = "owner_id"
        case threadId = "thread_id"
    }
}

struct ChatContribution: Codable, Hashable {
    let owners: [ContributionOwner]?
    let totalCost: Double?

    enum CodingKeys: String, CodingKey {
        case owners
        case totalCost = "total_cost"
    }
}

struct ContributionOwner: Codable, Hashable {
    let threadId: String?
    let ownerId: String?
    let documentIds: [String]?
    let spans: [TextSpan]?
    /// Exact per-source-file spans from the citation-marker path — keyed by the
    /// Thread document each highlighted range was drawn from. Nil when spans
    /// came from the n-gram heuristic alone.
    let documentSpans: [String: [TextSpan]]?
    let earning: Double?

    enum CodingKeys: String, CodingKey {
        case threadId = "thread_id"
        case ownerId = "owner_id"
        case documentIds = "document_ids"
        case spans
        case documentSpans = "document_spans"
        case earning
    }
}

struct TextSpan: Codable, Hashable {
    let lower: Int
    let upper: Int
}

/// One SSE chunk of the Sewn chat stream (OpenAI-shaped + Sewn extensions).
struct ChatChunk: Codable {
    let id: String?
    let model: String?
    let choices: [ChunkChoice]?
    let references: [ChatReference]?
    let contribution: ChatContribution?
    let personality: String?

    struct ChunkChoice: Codable {
        let delta: ChunkDelta?
    }

    struct ChunkDelta: Codable {
        let role: String?
        let content: String?
    }
}

/// Consolidated events the chat view consumes.
enum ChatEvent {
    case references([ChatReference])
    case delta(String)
    case contribution(ChatContribution)
    case personality(String)
    case done
}

// MARK: - Personalities

struct Personality: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var tagline: String
    var systemFragment: String
    var citationEmphasis: Bool
    var temperature: Double?
    var topP: Double?
    var modelOverride: String?

    enum CodingKeys: String, CodingKey {
        case id, name, tagline
        case systemFragment = "system_fragment"
        case citationEmphasis = "citation_emphasis"
        case temperature
        case topP = "top_p"
        case modelOverride = "model_override"
    }
}

struct PersonalitiesResponse: Codable {
    let personalities: [Personality]
}

// MARK: - Graph (Sewn proxy /v1/graph)

struct GraphQueryResponse: Codable {
    let entities: [GraphEntity]
    let relationships: [GraphRelationship]
    let documents: [GraphDocument]
    let stats: GraphStats?
}

struct GraphEntity: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let kind: String
    let score: Double?
    let mentionCount: Int?
    let documentIds: [String]?

    enum CodingKeys: String, CodingKey {
        case id, name, kind, score
        case mentionCount = "mention_count"
        case documentIds = "document_ids"
    }
}

struct GraphRelationship: Codable, Identifiable, Hashable {
    let id: String
    let subjectId: String
    let predicate: String
    let objectId: String
    let weight: Int?
    let documentIds: [String]?

    enum CodingKeys: String, CodingKey {
        case id
        case subjectId = "subject_id"
        case predicate
        case objectId = "object_id"
        case weight
        case documentIds = "document_ids"
    }
}

struct GraphDocument: Codable, Identifiable, Hashable {
    let id: String
    let name: String?
    let ownerId: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case ownerId = "owner_id"
    }
}

struct GraphStats: Codable, Hashable {
    let entityCount: Int
    let relationshipCount: Int

    enum CodingKeys: String, CodingKey {
        case entityCount = "entity_count"
        case relationshipCount = "relationship_count"
    }
}

// MARK: - Admin model

struct AdminModelResponse: Codable {
    let chatModel: String
    let utilityModel: String

    enum CodingKeys: String, CodingKey {
        case chatModel = "chat_model"
        case utilityModel = "utility_model"
    }
}

// MARK: - Search (trace overlay)

struct SearchResponseBody: Codable {
    let texts: [String]?
    let graph: SearchGraphBlock?
}

struct SearchGraphBlock: Codable {
    let matchedEntityIds: [String]?
    let expansionEdgeIds: [String]?
    let expandedDocuments: Int?

    enum CodingKeys: String, CodingKey {
        case matchedEntityIds = "matched_entity_ids"
        case expansionEdgeIds = "expansion_edge_ids"
        case expandedDocuments = "expanded_documents"
    }
}
