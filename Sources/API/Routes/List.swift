//
//  Documents.swift
//  seer-server
//
//  Created by Ritesh Pakala on 11/13/25.
//

import Foundation
import Hummingbird

func registerListDocumentsRoute(_ router: some RouterMethods<SeerRequestContext>,
                                _ seer: Seer) {
    router.post("/v1/list/documents") { request, context async throws -> DocumentListResponse in
        let documentRequest = try await request.decode(as: DocumentListRequest.self, context: context)
        let seerReq = try documentRequest.seer.from(context)
        let ownerId = seerReq.ownerId

        context.logger.info("Received documents request for owner: \(ownerId)")

        let (groups, _, _) = await seer.fanoutLibrary(ownerId: ownerId)

        var seen = Set<String>()
        var documents: [Seer.Document] = []
        for group in groups {
            for doc in group.documents where seen.insert(doc.id).inserted {
                documents.append(doc)
            }
        }

        return .init(documents: documents, access: [:])
    }
}

func registerListGroupsByDocumentsRoute(_ router: some RouterMethods<SeerRequestContext>,
                                        _ seer: Seer) {
    router.post("/v1/list/groups/documents") { request, context async throws -> GroupsByDocumentsResponse in
        let listRequest = try await request.decode(as: GroupsByDocumentsRequest.self, context: context)
        let seerReq = try listRequest.seer.from(context)
        let ownerId = seerReq.ownerId

        context.logger.info(
            "Received groups-by-documents request for owner: \(ownerId), documents: \(listRequest.documentIds.count)"
        )

        let (groups, documentGroups) = await seer.fanoutLibraryByDocuments(
            ownerId: ownerId,
            documentIds: listRequest.documentIds,
            totemIds: seerReq.totemIds
        )

        return GroupsByDocumentsResponse(groups: groups, documentGroups: documentGroups, access: [:])
    }
}

func registerListGroupsRoute(_ router: some RouterMethods<SeerRequestContext>,
                             _ seer: Seer) {
    router.post("/v1/list/groups") { request, context async throws -> GroupListResponse in
        let groupRequest = try await request.decode(as: GroupListRequest.self, context: context)
        let seerReq = try groupRequest.seer.from(context)
        let ownerId = seerReq.ownerId

        context.logger.info("Received groups request for owner: \(ownerId)")

        let limit   = groupRequest.limit
        let afterId = groupRequest.afterId ?? ""
        let totemIds = seerReq.totemIds
        let (groups, hasMore, nextAfterId) = await seer.fanoutLibrary(
            ownerId: ownerId,
            limit: limit,
            afterId: afterId,
            totemIds: totemIds
        )
        var resp = GroupListResponse(groups: groups, access: [:])
        resp.hasMore     = hasMore
        resp.nextAfterId = nextAfterId.isEmpty ? nil : nextAfterId
        return resp
    }
}
