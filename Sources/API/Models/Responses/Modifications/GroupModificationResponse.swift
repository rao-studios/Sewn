//
//  GroupModificationResponse.swift
//  seer-server
//
//  Created by Ritesh Pakala on 2/28/26.
//

import Foundation


struct GroupModificationResponse: Codable {
    let groupId: String
    let access: SeerRegistry.Access?
    let label: String?
    let user: Seer.User

    init(groupId: String,
         access: SeerRegistry.Access?,
         label: String? = nil,
         user: Seer.User) {
        self.groupId = groupId
        self.access = access
        self.label = label
        self.user = user
    }

    enum CodingKeys: String, CodingKey {
        case groupId = "group_id"
        case access
        case label
        case user
    }
}
