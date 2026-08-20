//
//  GroupMetadataRequest.swift
//  seer-server
//

import Foundation


struct GroupMetadataRequest: Codable {
    let groupId: String
    let label: String?
    let metadata: Seer.Group.Metadata
    let seer: SeerRequest

    enum CodingKeys: String, CodingKey {
        case groupId = "group_id"
        case label
        case metadata
        case seer
    }
}
