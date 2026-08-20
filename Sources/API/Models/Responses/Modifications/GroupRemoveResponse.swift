//
//  GroupRemoveResponse.swift
//  seer-server
//

import Foundation


struct GroupRemoveResponse: Codable {
    /// The group that was removed. `nil` if the caller does not own the group.
    let groupId: String?
    /// IDs of every document that was removed with the group.
    let documentIds: [String]
    let user: Seer.User

    enum CodingKeys: String, CodingKey {
        case groupId = "group_id"
        case documentIds = "document_ids"
        case user
    }
}
