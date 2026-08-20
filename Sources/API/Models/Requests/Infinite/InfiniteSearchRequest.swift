//
//  InfiniteSearchRequest.swift
//  seer-server
//

import Foundation


struct InfiniteSearchRequest: Codable {
    let query: String
    /// Maximum number of groups to return. Clamped to [1, 100]. Defaults to 20.
    let limit: Int?
    let seer: SeerRequest

    enum CodingKeys: String, CodingKey {
        case query
        case limit
        case seer
    }
}
