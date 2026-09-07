//
//  MarielleBridgeResponse.swift
//  Sewn
//
//  Created by Ritesh Pakala on 3/25/26.
//



/// Response for `POST /v1/marielle/bridge`.
struct MarielleBridgeResponse: Codable {
    /// The generated bridge question.
    var question: String
    /// Whether the question was grounded in shared territory (overlap)
    /// or the productive distance between two different worlds (contrast).
    var bridgeType: MariellebridgeType
    /// Most influential document from the requestor's side.
    var anchorDocumentIdA: String?
    /// Most influential document from the target's side.
    var anchorDocumentIdB: String?
    /// 0 = pure contrast bridge (no embedding overlap found),
    /// 1 = strong shared territory.
    var overlapScore: Float

    enum CodingKeys: String, CodingKey {
        case question
        case bridgeType       = "bridge_type"
        case anchorDocumentIdA = "anchor_document_id_a"
        case anchorDocumentIdB = "anchor_document_id_b"
        case overlapScore     = "overlap_score"
    }
}

enum MariellebridgeType: String, Codable {
    /// Grounded in topics both profiles are currently engaged with.
    case overlap
    /// Grounded in the space between two different current worlds.
    case contrast
}
