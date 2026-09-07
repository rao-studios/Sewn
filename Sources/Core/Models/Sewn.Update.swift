//
//  Sewn.Update.swift
//  sewn-server
//
//  Created by Ritesh Pakala Rao on 12/15/25.
//

import Foundation


// TODO: What differentiates this from ModifyRequest?
/// A payload to manage metadata for updations. A necessary data object
/// when updating documents or other data types. Maintaining data consistency
/// with the clients.
struct SewnUpdate: Codable {
    let documentId: String
    let operation: Operation
    /// For `.group` — the target group to move the document into.
    let targetGroupId: String?

    enum CodingKeys: String, CodingKey {
        case documentId    = "document_id"
        case operation
        case targetGroupId = "target_group_id"
    }
}

extension SewnUpdate {
    enum Operation: String, Codable {
        case remove
        case access
        case group
    }
}
