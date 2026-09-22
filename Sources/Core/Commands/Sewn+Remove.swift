//
//  Sewn+Index.swift
//  sewn-server
//
//  Created by Ritesh Pakala on 11/15/25.
//
//  Every remove takes the SewnRequest it acts for: its `threadIds` narrow
//  the broadcast, and its `callerApp` scopes it to that app's Threads.
//

import Foundation

extension Sewn {
    /// Broadcasts remove for all documents owned by a user to the caller's active Thread nodes.
    /// Thread is the source of truth — no local registry or file operations.
    @discardableResult
    func _removeAll(ownerId: String, request: SewnRequest) async -> Int {
        if _threadQueryClient != nil {
            // Broadcast to all Threads — each will remove what it holds for this owner.
            // We don't have a local list of doc IDs anymore; Thread handles the filtering.
            await fanoutRemove(documentIds: [], ownerId: ownerId,
                               targetThreadIds: request.threadIds, app: request.callerApp)
        } else {
            logger.warning("_removeAll: no Thread connected — vectors not removed", service: .sewn, request: request)
        }
        return 0
    }

    /// Broadcasts remove for a batch of (documentId, ownerId) pairs to the caller's active Thread nodes.
    func _removeBatch(items: [(documentId: String, ownerId: String)], request: SewnRequest) async {
        guard !items.isEmpty else { return }
        if _threadQueryClient != nil {
            let byOwner = Dictionary(grouping: items, by: \.ownerId)
            for (ownerId, ownerItems) in byOwner {
                await fanoutRemove(documentIds: ownerItems.map(\.documentId), ownerId: ownerId,
                                   targetThreadIds: request.threadIds, app: request.callerApp)
            }
        } else {
            logger.warning("_removeBatch: no Thread connected — vectors not removed", service: .sewn)
        }
    }

    /// Broadcasts remove for a single document to the caller's active Thread nodes.
    func remove(documentId: String,
                group: Sewn.Group? = nil,
                ownerId: String,
                request: SewnRequest) async {
        logger.info("Remove Document", "Broadcasting remove for document: \(documentId)", service: .sewn)
        if _threadQueryClient != nil {
            await fanoutRemove(documentIds: [documentId], ownerId: ownerId,
                               targetThreadIds: request.threadIds, app: request.callerApp)
        } else {
            logger.warning("remove: no Thread connected — vectors not removed", service: .sewn)
        }
    }
}
