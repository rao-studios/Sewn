//
//  Documents.swift
//  sewn-server
//
//  Created by Ritesh Pakala on 11/13/25.
//

import Foundation
import Hummingbird

func registerListDocumentsRoute(_ router: some RouterMethods<SewnRequestContext>,
                                _ sewn: Sewn) {
    router.post("/v1/list/documents") { request, context async throws -> DocumentListResponse in
        let documentRequest = try await request.decode(as: DocumentListRequest.self, context: context)
        let sewnReq = try documentRequest.sewn.from(context)
        let ownerId = sewnReq.ownerId

        context.logger.info("Received documents request for owner: \(ownerId)")

        let (groups, _, _) = await sewn.fanoutLibrary(ownerId: ownerId, app: sewnReq.callerApp)

        var seen = Set<String>()
        var documents: [Sewn.Document] = []
        for group in groups {
            for doc in group.documents where seen.insert(doc.id).inserted {
                documents.append(doc)
            }
        }

        return .init(documents: documents, access: [:])
    }
}

func registerListGroupsByDocumentsRoute(_ router: some RouterMethods<SewnRequestContext>,
                                        _ sewn: Sewn) {
    router.post("/v1/list/groups/documents") { request, context async throws -> GroupsByDocumentsResponse in
        let listRequest = try await request.decode(as: GroupsByDocumentsRequest.self, context: context)
        let sewnReq = try listRequest.sewn.from(context)
        let ownerId = sewnReq.ownerId

        context.logger.info(
            "Received groups-by-documents request for owner: \(ownerId), documents: \(listRequest.documentIds.count)"
        )

        let (groups, documentGroups) = await sewn.fanoutLibraryByDocuments(
            ownerId: ownerId,
            documentIds: listRequest.documentIds,
            threadIds: sewnReq.threadIds,
            app: sewnReq.callerApp
        )

        return GroupsByDocumentsResponse(groups: groups, documentGroups: documentGroups, access: [:])
    }
}

func registerListGroupsRoute(_ router: some RouterMethods<SewnRequestContext>,
                             _ sewn: Sewn) {
    router.post("/v1/list/groups") { request, context async throws -> GroupListResponse in
        let groupRequest = try await request.decode(as: GroupListRequest.self, context: context)
        let sewnReq = try groupRequest.sewn.from(context)
        let ownerId = sewnReq.ownerId

        context.logger.info("Received groups request for owner: \(ownerId)")

        let limit   = groupRequest.limit
        let afterId = groupRequest.afterId ?? ""
        let threadIds = sewnReq.threadIds
        let (groups, hasMore, nextAfterId) = await sewn.fanoutLibrary(
            ownerId: ownerId,
            limit: limit,
            afterId: afterId,
            threadIds: threadIds,
            app: sewnReq.callerApp
        )
        var resp = GroupListResponse(groups: groups, access: [:])
        resp.hasMore     = hasMore
        resp.nextAfterId = nextAfterId.isEmpty ? nil : nextAfterId
        return resp
    }
}
