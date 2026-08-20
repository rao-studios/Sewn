//
//  MarielleInterjectResponse.swift
//  Seer
//
//  Created by Ritesh Pakala on 3/25/26.
//



/// Response for `POST /v1/marielle/interject`.
struct MarielleInterjectResponse: Codable {
    /// Whether Marielle has a question worth surfacing right now.
    /// When false, all optional fields are nil and the client should not interject.
    var shouldInterject: Bool
    /// The generated lateral question. nil when `shouldInterject` is false.
    var question: String?
    /// Document ID of the most influential uncited node. nil when not interjecting.
    var anchorDocumentId: String?
    /// Human-readable title / URL of the anchor document.
    var anchorTitle: String?
    /// Raw interjection score (0–1). Useful for client-side gating or debug display.
    var score: Float

    enum CodingKeys: String, CodingKey {
        case shouldInterject  = "should_interject"
        case question
        case anchorDocumentId = "anchor_document_id"
        case anchorTitle      = "anchor_title"
        case score
    }
}
