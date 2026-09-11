//
//  MarielleBridgeRequest.swift
//  Sewn
//
//  Created by Ritesh Pakala on 3/25/26.
//



/// Request for `POST /v1/marielle/bridge`.
/// Merges the requestor's personal HNSW with a target profile's HNSW and
/// generates a question that bridges both worlds, weighted by the recency
/// of each person's documents.
struct MarielleBridgeRequest: Codable {
    let sewn: SewnRequest
    /// UUID of the second profile to bridge with.
    /// That profile must have bridging enabled in the registry.
    let targetProfileId: String

    enum CodingKeys: String, CodingKey {
        case sewn
        case targetProfileId = "target_profile_id"
    }
}
