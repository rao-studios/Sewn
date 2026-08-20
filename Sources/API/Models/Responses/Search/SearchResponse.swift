//
//  SearchResponse.swift
//  swift-mlx-server
//
//  Created by Ritesh Pakala on 11/1/25.
//

/// The knowledge-graph context for a fused search, merged across Totem nodes:
/// which entities the query matched and how many documents the one-hop
/// expansion pulled in. IDs are graph-store entity/relationship hashes;
/// resolve names via `POST /v1/graph`.
struct SearchResponseGraph: Codable {
    let matchedEntityIds: [String]
    let expansionEdgeIds: [String]
    let expandedDocuments: Int

    enum CodingKeys: String, CodingKey {
        case matchedEntityIds = "matched_entity_ids"
        case expansionEdgeIds = "expansion_edge_ids"
        case expandedDocuments = "expanded_documents"
    }
}

struct SearchResponse: Codable {
    var object: String = "list"
    let texts: [String]
    let references: [Seer.DocumentReference]
    let contribution: Gita.Contribution?
    let graph: SearchResponseGraph?

    enum CodingKeys: String, CodingKey {
        case object
        case texts
        case references
        case contribution
        case graph
    }
}
