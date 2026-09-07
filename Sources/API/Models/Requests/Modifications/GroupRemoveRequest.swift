//
//  GroupRemoveRequest.swift
//  sewn-server
//

import Foundation


struct GroupRemoveRequest: Codable {
    let groupId: String
    let sewn: SewnRequest

    enum CodingKeys: String, CodingKey {
        case groupId = "group_id"
        case sewn
    }
}
