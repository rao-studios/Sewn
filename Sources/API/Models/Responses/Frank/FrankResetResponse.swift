//
//  FrankResetResponse.swift
//  seer-server
//



/// Returned by `POST /v1/frank/reset`.
struct FrankResetResponse: Codable {
    /// `true` if the owner had any Sinatra data that was cleared.
    /// `false` if the registry was already empty for this owner (no-op).
    let reset: Bool
    let ownerId: String

    enum CodingKeys: String, CodingKey {
        case reset
        case ownerId = "owner_id"
    }
}
