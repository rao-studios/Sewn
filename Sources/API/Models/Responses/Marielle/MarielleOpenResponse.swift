//
//  MarielleOpenResponse.swift
//  Sewn
//
//  Created by Ritesh Pakala on 3/25/26.
//



/// Response for `POST /v1/marielle/open`.
struct MarielleOpenResponse: Codable {
    /// The generated opening question.
    var question: String
    /// Document ID of the most influential node in the candidate set.
    var anchorDocumentId: String
    /// Human-readable title / URL of the anchor document.
    var anchorTitle: String
    /// 0–1 confidence derived from the sharpness of the recency signal.
    /// High = one topic clearly dominates; low = many equally recent topics.
    var confidence: Float
    /// What caused this open to be generated.
    var trigger: MarielleOpenTrigger

    enum CodingKeys: String, CodingKey {
        case question
        case anchorDocumentId = "anchor_document_id"
        case anchorTitle      = "anchor_title"
        case confidence
        case trigger
    }
}

enum MarielleOpenTrigger: String, Codable {
    /// Called explicitly by the client at the start of a session.
    case requested
    /// Marielle determined it had something worth saying unprompted.
    case proactive
    /// Fired by a server-side scheduled condition.
    case scheduled
}
