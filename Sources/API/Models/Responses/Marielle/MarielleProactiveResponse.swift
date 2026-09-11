//
//  MarielleProactiveResponse.swift
//  Sewn
//
//  Created by Ritesh Pakala on 3/25/26.
//



/// Response for `POST /v1/marielle/proactive`.
/// A lightweight check — the client polls this before committing to
/// a full `/v1/marielle/open` call. When `available` is true the
/// client may present a subtle affordance and then fetch the question.
struct MarielleProactiveResponse: Codable {
    /// Whether Marielle's trigger score exceeds the proactive threshold.
    var available: Bool
    /// Raw trigger score (0–1). Useful for debug / analytics.
    var score: Float

    enum CodingKeys: String, CodingKey {
        case available
        case score
    }
}
