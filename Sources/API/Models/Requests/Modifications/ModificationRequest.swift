//
//  ModificationRequest.swift
//  sewn-server
//
//  Created by Ritesh Pakala on 11/8/25.
//

import Foundation


struct ModificationRequest: Codable {
    let documentAccess: SewnRegistry.Access?
    let groupAccess: SewnRegistry.Access?
    let update: SewnUpdate
    let sewn: SewnRequest
    
    enum CodingKeys: String, CodingKey {
        case documentAccess = "document_access"
        case groupAccess = "group_access"
        case update
        case sewn
    }
}
