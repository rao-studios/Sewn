//
//  StorageBackupResponse.swift
//  sewn-server
//
//  Created by Ritesh Pakala Rao on 2/27/26.
//

import Foundation


struct StorageBackupResponse: Codable {
    var object: String = "storage.backup"
    let ownerId: String
    let backedUpCount: Int
    let failedCount: Int
    let backedUpAt: Date

    enum CodingKeys: String, CodingKey {
        case object
        case ownerId      = "owner_id"
        case backedUpCount = "backed_up_count"
        case failedCount  = "failed_count"
        case backedUpAt   = "backed_up_at"
    }
}
