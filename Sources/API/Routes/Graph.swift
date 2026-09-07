//
//  Graph.swift
//  sewn-server
//
//  Created by Ritesh Pakala on 7/16/26.
//

import Foundation
import Hummingbird

// MARK: - Request / Response models

/// A knowledge-graph query proxied to the Thread fleet: resolve entities by name and/or
/// free-text similarity, then traverse up to `hops` edges. At least one of
/// `entity` / `query` must be present.
struct GraphProxyRequest: Codable {
    let sewn: SewnRequest
    /// Entity name lookup (token containment).
    let entity: String?
    /// Free-text query; each Thread embeds it locally for similarity matching.
    let query: String?
    /// Restrict matches to these entity kinds.
    let kinds: [String]?
    /// Traversal depth (0–3). Defaults to 1.
    let hops: Int?
    /// Max entities returned per Thread. Defaults to 20.
    let limit: Int?
    /// Whether to resolve linked documents. Defaults to true.
    let includeDocuments: Bool?

    enum CodingKeys: String, CodingKey {
        case sewn
        case entity
        case query
        case kinds
        case hops
        case limit
        case includeDocuments = "include_documents"
    }
}

struct GraphProxyEntity: Codable {
    let id: String
    let name: String
    let kind: String
    let score: Float
    let mentionCount: Int
    let documentIds: [String]

    enum CodingKeys: String, CodingKey {
        case id, name, kind, score
        case mentionCount = "mention_count"
        case documentIds = "document_ids"
    }
}

struct GraphProxyRelationship: Codable {
    let id: String
    let subjectId: String
    let predicate: String
    let objectId: String
    let weight: Int
    let documentIds: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case subjectId = "subject_id"
        case predicate
        case objectId = "object_id"
        case weight
        case documentIds = "document_ids"
    }
}

struct GraphProxyDocument: Codable {
    let id: String
    let name: String?
    let ownerId: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case ownerId = "owner_id"
    }
}

struct GraphProxyStats: Codable {
    let entityCount: Int
    let relationshipCount: Int

    enum CodingKeys: String, CodingKey {
        case entityCount = "entity_count"
        case relationshipCount = "relationship_count"
    }
}

struct GraphProxyResponse: Codable {
    var object: String = "graph"
    let entities: [GraphProxyEntity]
    let relationships: [GraphProxyRelationship]
    let documents: [GraphProxyDocument]
    let stats: GraphProxyStats
}

// MARK: - Route

func registerGraphRoute(
    _ router: some RouterMethods<SewnRequestContext>,
    _ sewn: Sewn
) {
    router.post("/v1/graph") { request, context async throws -> GraphProxyResponse in
        let graphReq = try await request.decode(as: GraphProxyRequest.self, context: context)
        let sewnReq = try graphReq.sewn.from(context)

        guard graphReq.entity != nil || graphReq.query != nil else {
            throw HTTPError(.badRequest, message: "Provide 'entity' and/or 'query'.")
        }

        let merged = await sewn.fanoutGraph(
            ownerId: sewnReq.ownerId,
            entity: graphReq.entity,
            query: graphReq.query,
            kinds: graphReq.kinds ?? [],
            hops: graphReq.hops ?? 1,
            limit: graphReq.limit ?? 20,
            includeDocuments: graphReq.includeDocuments ?? true
        )

        return GraphProxyResponse(
            entities: merged.entities.map {
                GraphProxyEntity(id: $0.id, name: $0.name, kind: $0.kind, score: $0.score,
                                 mentionCount: Int($0.mentionCount), documentIds: $0.documentIds)
            },
            relationships: merged.relationships.map {
                GraphProxyRelationship(id: $0.id, subjectId: $0.subjectID, predicate: $0.predicate,
                                       objectId: $0.objectID, weight: Int($0.weight),
                                       documentIds: $0.documentIds)
            },
            documents: merged.documents.map {
                GraphProxyDocument(id: $0.id,
                                   name: $0.name.isEmpty ? nil : $0.name,
                                   ownerId: $0.ownerID.isEmpty ? nil : $0.ownerID)
            },
            stats: GraphProxyStats(entityCount: Int(merged.stats.entityCount),
                                   relationshipCount: Int(merged.stats.relationshipCount))
        )
    }
}
