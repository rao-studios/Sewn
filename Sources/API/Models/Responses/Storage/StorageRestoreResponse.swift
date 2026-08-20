//
//  StorageRestoreResponse.swift
//  seer-server
//
//  Created by Ritesh Pakala Rao on 2/28/26.
//

import Foundation


struct StorageRestoreResponse: Codable {
    var object: String = "storage.restore"
    let ownerId: String
    let documents: [BackupDocumentEnvelope]
    let downloadedCount: Int
    let failedCount: Int
    /// `true` when all documents downloaded successfully and the server-side
    /// index has been purged and is ready for re-ingestion.
    /// `false` when one or more downloads failed — the server index is
    /// untouched; the client should not proceed with re-ingestion.
    let success: Bool

    enum CodingKeys: String, CodingKey {
        case object
        case ownerId         = "owner_id"
        case documents
        case downloadedCount = "downloaded_count"
        case failedCount     = "failed_count"
        case success
    }
}
