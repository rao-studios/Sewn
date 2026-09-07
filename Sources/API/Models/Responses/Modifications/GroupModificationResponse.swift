//
//  GroupModificationResponse.swift
//  sewn-server
//
//  Created by Ritesh Pakala on 2/28/26.
//

import Foundation


struct GroupModificationResponse: Codable {
    let groupId: String
    let access: SewnRegistry.Access?
    let label: String?
    let user: Sewn.User

    init(groupId: String,
         access: SewnRegistry.Access?,
         label: String? = nil,
         user: Sewn.User) {
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
