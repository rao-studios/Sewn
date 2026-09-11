//
//  GroupMetadataResponse.swift
//  sewn-server
//

import Foundation


struct GroupMetadataResponse: Codable {
    let groupId: String
    let label: String?
    let metadata: Sewn.Group.Metadata?
    let user: Sewn.User

    enum CodingKeys: String, CodingKey {
        case groupId = "group_id"
        case label
        case metadata
        case user
    }
}
