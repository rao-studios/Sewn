//
//  ModificationResponse.swift
//  sewn-server
//
//  Created by Ritesh Pakala on 11/8/25.
//

import Foundation


struct ModificationResponse: Codable {
    var document: Sewn.Document?
    var documentAccess: SewnRegistry.Access?
    var groupAccess: SewnRegistry.Access?
    var groupId: String?
    var user: Sewn.User
    
    enum CodingKeys: String, CodingKey {
        case document
        case documentAccess = "document_access"
        case groupAccess = "group_access"
        case groupId = "group_id"
        case user
    }
}
