//
//  ModificationRequest.swift
//  seer-server
//
//  Created by Ritesh Pakala on 11/8/25.
//

import Foundation


struct ModificationRequest: Codable {
    let documentAccess: SeerRegistry.Access?
    let groupAccess: SeerRegistry.Access?
    let update: SeerUpdate
    let seer: SeerRequest
    
    enum CodingKeys: String, CodingKey {
        case documentAccess = "document_access"
        case groupAccess = "group_access"
        case update
        case seer
    }
}
