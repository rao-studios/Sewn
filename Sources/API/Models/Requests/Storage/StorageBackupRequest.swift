//
//  StorageBackupRequest.swift
//  sewn-server
//
//  Created by Ritesh Pakala Rao on 2/27/26.
//

import Foundation


/// A single document sent from the iOS client for cloud backup.
/// The envelope is stored verbatim as a JSON file in Supabase Storage
/// at `{userId}/{groupId}/{documentId}`.
struct BackupDocumentEnvelope: Codable {
    /// Schema version. 1 = plaintext. 2 (future) = AES-256-GCM encrypted text.
    var version: Int = 1
    let documentId: String
    let groupId: String
    let groupLabel: String?
    let ownerId: String
    let url: URL?
    let text: String
    let backedUpAt: Date

    enum CodingKeys: String, CodingKey {
        case version
        case documentId  = "document_id"
        case groupId     = "group_id"
        case groupLabel  = "group_label"
        case ownerId     = "owner_id"
        case url
        case text
        case backedUpAt  = "backed_up_at"
    }
}

struct StorageBackupRequest: Codable {
    let sewn: SewnRequest
    let documents: [BackupDocumentEnvelope]
}
