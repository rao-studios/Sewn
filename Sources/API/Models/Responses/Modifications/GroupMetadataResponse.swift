//
//  GroupMetadataResponse.swift
//  seer-server
//

import Foundation


struct GroupMetadataResponse: Codable {
    let groupId: String
    let label: String?
    let metadata: Seer.Group.Metadata?
    let user: Seer.User

    enum CodingKeys: String, CodingKey {
        case groupId = "group_id"
        case label
        case metadata
        case user
    }
}
