//
//  StoragePurgeResponse.swift
//  seer-server
//
//  Created by Ritesh Pakala Rao on 2/27/26.
//

import Foundation


struct StoragePurgeResponse: Codable {
    var object: String = "storage.purge"
    let ownerId: String
    let purgedCount: Int

    enum CodingKeys: String, CodingKey {
        case object
        case ownerId     = "owner_id"
        case purgedCount = "purged_count"
    }
}
