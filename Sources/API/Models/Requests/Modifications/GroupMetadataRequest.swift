//
//  GroupMetadataRequest.swift
//  sewn-server
//

import Foundation


struct GroupMetadataRequest: Codable {
    let groupId: String
    let label: String?
    let metadata: Sewn.Group.Metadata
    let sewn: SewnRequest

    enum CodingKeys: String, CodingKey {
        case groupId = "group_id"
        case label
        case metadata
        case sewn
    }
}
