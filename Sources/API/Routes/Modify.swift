//
//  Modify.swift
//  sewn-server
//
//  Created by Ritesh Pakala on 11/8/25.
//

import Foundation
import Hummingbird

/// `POST /v1/modify`
///
/// General-purpose document modification endpoint. Dispatches one of three
/// operations based on `update.operation`:
///
/// - `.remove`  — Removes the document (and its group association) from Thread.
/// - `.access`  — Pending Thread endpoints; returns success=false.
/// - `.group`   — Pending Thread endpoints; returns success=false.
func registerModifyRoute(_ router: some RouterMethods<SewnRequestContext>,
                         _ sewn: Sewn) {
    router.post("/v1/modify") { request, context async throws -> ModificationResponse in
        let modifyRequest = try await request.decode(as: ModificationRequest.self, context: context)
        let sewnReq = try modifyRequest.sewn.from(context)
        let ownerId = sewnReq.ownerId
        let id = modifyRequest.update.documentId
        let group = modifyRequest.sewn.group
        let update = modifyRequest.update

        context.logger.info(
            "Received modify request for owner: \(ownerId), op: \(update.operation.rawValue)"
        )

        var resolvedDocumentAccess: SewnRegistry.Access? = nil
        var resolvedGroupId: String? = nil

        switch update.operation {
        case .remove:
            await sewn.remove(documentId: id, group: group, ownerId: ownerId, request: sewnReq)
        case .access:
            if let newAccess = modifyRequest.documentAccess {
                let ok = await sewn.fanoutUpdateDocument(
                    documentId: id,
                    ownerId: ownerId,
                    access: newAccess.rawValue,
                    groupId: nil,
                    app: sewnReq.callerApp
                )
                if ok { resolvedDocumentAccess = newAccess }
                context.logger.info("modify .access — documentId: \(id), access: \(newAccess.rawValue), success: \(ok)")
            }
        case .group:
            if let targetGroupId = update.targetGroupId {
                let ok = await sewn.fanoutUpdateDocument(
                    documentId: id,
                    ownerId: ownerId,
                    access: nil,
                    groupId: targetGroupId,
                    app: sewnReq.callerApp
                )
                if ok { resolvedGroupId = targetGroupId }
                context.logger.info("modify .group — documentId: \(id), targetGroup: \(targetGroupId), success: \(ok)")
            }
        }

        return .init(document: sewn.document(for: id),
                     documentAccess: resolvedDocumentAccess,
                     groupAccess: nil,
                     groupId: resolvedGroupId,
                     user: sewn.user(for: ownerId))
    }
}

/// `POST /v1/modify/group/remove`
///
/// Removes a group and all of its documents from Thread in a single operation.
/// Ownership is verified by checking that the group is owned by the caller
/// in the fan-out library response.
///
/// Returns `group_id: nil` and an empty `document_ids` array if the caller
/// does not own the group or the group does not exist.
func registerModifyGroupRemoveRoute(_ router: some RouterMethods<SewnRequestContext>,
                                    _ sewn: Sewn) {
    router.post("/v1/modify/group/remove") { request, context async throws -> GroupRemoveResponse in
        let removeRequest = try await request.decode(as: GroupRemoveRequest.self, context: context)
        let sewnReq = try removeRequest.sewn.from(context)
        let ownerId = sewnReq.ownerId
        let groupId = removeRequest.groupId

        context.logger.info(
            "Received modify-group-remove request for group: \(groupId), owner: \(ownerId)"
        )

        let (groups, _, _) = await sewn.fanoutLibrary(ownerId: ownerId, app: sewnReq.callerApp)
        guard let group = groups.first(where: { $0.id == groupId && $0.ownerId == ownerId }) else {
            context.logger.warning(
                "modify-group-remove rejected — owner \(ownerId) does not own group \(groupId)"
            )
            return .init(groupId: nil, documentIds: [], user: sewn.user(for: ownerId))
        }

        let documentIds = group.documents.map(\.id)
        await sewn._removeBatch(items: documentIds.map { ($0, ownerId) }, request: sewnReq)

        context.logger.info(
            "modify-group-remove complete — group \(groupId) removed with \(documentIds.count) document(s)"
        )

        return .init(groupId: groupId, documentIds: documentIds, user: sewn.user(for: ownerId))
    }
}

/// `POST /v1/modify/group/access`
///
/// Updates group access level and/or label. Ownership is verified before mutating.
func registerModifyGroupRoute(_ router: some RouterMethods<SewnRequestContext>,
                              _ sewn: Sewn) {
    router.post("/v1/modify/group/access") { request, context async throws -> GroupModificationResponse in
        let modifyRequest = try await request.decode(as: GroupModificationRequest.self, context: context)
        let sewnReq = try modifyRequest.sewn.from(context)
        let ownerId = sewnReq.ownerId
        let groupId = modifyRequest.groupId

        context.logger.info("Received modify-group request for group: \(groupId), owner: \(ownerId)")

        let (groups, _, _) = await sewn.fanoutLibrary(ownerId: ownerId, app: sewnReq.callerApp)
        guard groups.contains(where: { $0.id == groupId && $0.ownerId == ownerId }) else {
            context.logger.warning("modify-group rejected — owner \(ownerId) does not own group \(groupId)")
            return .init(groupId: groupId, access: nil, label: nil, user: sewn.user(for: ownerId))
        }

        let success = await sewn.fanoutUpdateGroup(
            groupId: groupId,
            ownerId: ownerId,
            access: modifyRequest.access.rawValue,
            label: modifyRequest.label,
            description: nil,
            tags: nil,
            app: sewnReq.callerApp
        )

        context.logger.info("modify-group complete — group \(groupId), success=\(success)")
        return .init(
            groupId: groupId,
            access:  success ? modifyRequest.access : nil,
            label:   success ? modifyRequest.label : nil,
            user:    sewn.user(for: ownerId)
        )
    }
}

/// `POST /v1/modify/group/metadata`
///
/// Updates group description and tags. Ownership is verified before mutating.
func registerModifyGroupMetadataRoute(_ router: some RouterMethods<SewnRequestContext>,
                                      _ sewn: Sewn) {
    router.post("/v1/modify/group/metadata") { request, context async throws -> GroupMetadataResponse in
        let metadataRequest = try await request.decode(as: GroupMetadataRequest.self, context: context)
        let sewnReq = try metadataRequest.sewn.from(context)
        let ownerId = sewnReq.ownerId
        let groupId = metadataRequest.groupId
        let meta = metadataRequest.metadata

        context.logger.info(
            "Received modify-group-metadata request for group: \(groupId), owner: \(ownerId)"
        )

        let (groups, _, _) = await sewn.fanoutLibrary(ownerId: ownerId, app: sewnReq.callerApp)
        guard groups.contains(where: { $0.id == groupId && $0.ownerId == ownerId }) else {
            context.logger.warning("modify-group-metadata rejected — owner \(ownerId) does not own group \(groupId)")
            return .init(groupId: groupId, label: nil, metadata: nil, user: sewn.user(for: ownerId))
        }

        let success = await sewn.fanoutUpdateGroup(
            groupId: groupId,
            ownerId: ownerId,
            access: nil,
            label: metadataRequest.label,
            description: meta.description,
            tags: meta.tags,
            updateMetadata: true,
            app: sewnReq.callerApp
        )

        context.logger.info("modify-group-metadata complete — group \(groupId), success=\(success)")
        return .init(
            groupId:  groupId,
            label:    success ? metadataRequest.label : nil,
            metadata: success ? meta : nil,
            user:     sewn.user(for: ownerId)
        )
    }
}
