//
//  GroupModificationRequest.swift
//  seer-server
//
//  Created by Ritesh Pakala on 2/28/26.
//

import Foundation


struct GroupModificationRequest: Codable {
    let groupId: String
    let access: SeerRegistry.Access
    let label: String?
    let seer: SeerRequest

    enum CodingKeys: String, CodingKey {
        case groupId = "group_id"
        case access
        case label
        case seer
    }
}
