//
//  GroupListResponse.swift
//  sewn-server
//
//  Created by Ritesh Pakala Rao on 12/10/25.
//

import Foundation


struct GroupListResponse: Codable {
    var object: String = "list"
    let groups: [Sewn.Group]
    let access: [GroupID: SewnRegistry.Access]
    var hasMore: Bool = false
    var nextAfterId: String? = nil

    enum CodingKeys: String, CodingKey {
        case object, groups, access
        case hasMore     = "has_more"
        case nextAfterId = "next_after_id"
    }
}
