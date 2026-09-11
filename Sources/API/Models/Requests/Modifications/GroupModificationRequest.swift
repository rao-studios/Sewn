//
//  GroupModificationRequest.swift
//  sewn-server
//
//  Created by Ritesh Pakala on 2/28/26.
//

import Foundation


struct GroupModificationRequest: Codable {
    let groupId: String
    let access: SewnRegistry.Access
    let label: String?
    let sewn: SewnRequest

    enum CodingKeys: String, CodingKey {
        case groupId = "group_id"
        case access
        case label
        case sewn
    }
}
