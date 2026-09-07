//
//  MarielleInterjectRequest.swift
//  Sewn
//
//  Created by Ritesh Pakala on 3/25/26.
//



/// Request for `POST /v1/marielle/interject`.
/// Carries the current session messages so Marielle can score whether to
/// surface a lateral question, and which nodes are already in context so
/// the interjection targets something genuinely new.
struct MarielleInterjectRequest: Codable {
    let sewn: SewnRequest
    /// Current session turns. Used to embed the conversational direction
    /// and compute drift / saturation scores.
    let messages: [ChatMessageRequestData]
    /// Partition IDs already returned in prior retrieval results this session.
    /// Marielle only surfaces nodes not yet cited.
    let lastContextPartitionIds: [String]?

    enum CodingKeys: String, CodingKey {
        case sewn
        case messages
        case lastContextPartitionIds = "last_context_partition_ids"
    }
}
