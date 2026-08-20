//
//  ModificationResponse.swift
//  seer-server
//
//  Created by Ritesh Pakala on 11/8/25.
//

import Foundation


struct ModificationResponse: Codable {
    var document: Seer.Document?
    var documentAccess: SeerRegistry.Access?
    var groupAccess: SeerRegistry.Access?
    var groupId: String?
    var user: Seer.User
    
    enum CodingKeys: String, CodingKey {
        case document
        case documentAccess = "document_access"
        case groupAccess = "group_access"
        case groupId = "group_id"
        case user
    }
}
