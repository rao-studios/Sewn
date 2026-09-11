//
//  InfiniteSearchResponse.swift
//  sewn-server
//

import Foundation


struct InfiniteSearchResponse: Codable {
    var object: String = "list"
    let groups: [Sewn.Group]
    let total: Int

    enum CodingKeys: String, CodingKey {
        case object
        case groups
        case total
    }
}
