//
//  GroupRemoveRequest.swift
//  seer-server
//

import Foundation


struct GroupRemoveRequest: Codable {
    let groupId: String
    let seer: SeerRequest

    enum CodingKeys: String, CodingKey {
        case groupId = "group_id"
        case seer
    }
}
