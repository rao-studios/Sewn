//
//  Seer+Index.swift
//  seer-server
//
//  Created by Ritesh Pakala on 11/15/25.
//

import Foundation

extension Seer {
    /// Broadcasts remove for all documents owned by a user to all active Totem nodes.
    /// Totem is the source of truth — no local registry or file operations.
    @discardableResult
    func _removeAll(ownerId: String, request: SeerRequest) async -> Int {
        if _totemQueryClient != nil {
            // Broadcast to all Totems — each will remove what it holds for this owner.
            // We don't have a local list of doc IDs anymore; Totem handles the filtering.
            await fanoutRemove(documentIds: [], ownerId: ownerId,
                               targetTotemIds: request.totemIds)
        } else {
            logger.warning("_removeAll: no Totem connected — vectors not removed", service: .seer, request: request)
        }
        return 0
    }

    /// Broadcasts remove for a batch of (documentId, ownerId) pairs to all active Totem nodes.
    func _removeBatch(items: [(documentId: String, ownerId: String)], request: SeerRequest? = nil) async {
        guard !items.isEmpty else { return }
        if _totemQueryClient != nil {
            let byOwner = Dictionary(grouping: items, by: \.ownerId)
            for (ownerId, ownerItems) in byOwner {
                await fanoutRemove(documentIds: ownerItems.map(\.documentId), ownerId: ownerId,
                                   targetTotemIds: request?.totemIds)
            }
        } else {
            logger.warning("_removeBatch: no Totem connected — vectors not removed", service: .seer)
        }
    }

    /// Broadcasts remove for a single document to all active Totem nodes.
    func remove(documentId: String,
                group: Seer.Group? = nil,
                ownerId: String,
                request: SeerRequest? = nil) async {
        logger.info("Remove Document", "Broadcasting remove for document: \(documentId)", service: .seer)
        if _totemQueryClient != nil {
            await fanoutRemove(documentIds: [documentId], ownerId: ownerId,
                               targetTotemIds: request?.totemIds)
        } else {
            logger.warning("remove: no Totem connected — vectors not removed", service: .seer)
        }
    }
}
