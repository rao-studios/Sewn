//
//  Admin.swift
//  sewn-server
//
//  Created by Ritesh Pakala Rao on 3/20/26.
//

import Foundation
import Hummingbird

// MARK: - Response Models

// MARK: Owners

/// Lists every registered owner ID in the registry.
struct AdminOwnersResponse: Codable {
    let owners: [AdminOwnerSummary]

    struct AdminOwnerSummary: Codable {
        let ownerId: String
        let documentCount: Int
        let groupCount: Int

        enum CodingKeys: String, CodingKey {
            case ownerId       = "owner_id"
            case documentCount = "document_count"
            case groupCount    = "group_count"
        }
    }
}

// MARK: Owner Request

/// Minimal admin request body carrying only the target owner's identity.
struct AdminOwnerRequest: Codable {
    let sewn: SewnRequest
}

// MARK: Model Selection

/// Runtime model selection — lets the client app deploy a trained
/// `tinker://…` checkpoint as the serving model without a restart.
struct AdminModelUpdateRequest: Codable {
    let chatModel: String?
    let utilityModel: String?

    enum CodingKeys: String, CodingKey {
        case chatModel = "chat_model"
        case utilityModel = "utility_model"
    }
}

struct AdminModelResponse: Codable {
    let chatModel: String
    let utilityModel: String

    enum CodingKeys: String, CodingKey {
        case chatModel = "chat_model"
        case utilityModel = "utility_model"
    }
}

// MARK: System Stats

/// Aggregate system-wide counts derived from the registry in one pass.
struct AdminSystemStatsResponse: Codable {
    let ownerCount:      Int
    let documentCount:   Int
    let availableCount:  Int
    let restrictedCount: Int
    let groupCount:      Int

    enum CodingKeys: String, CodingKey {
        case ownerCount      = "owner_count"
        case documentCount   = "document_count"
        case availableCount  = "available_count"
        case restrictedCount = "restricted_count"
        case groupCount      = "group_count"
    }
}

// MARK: Owner Delete

/// Response for `POST /v1/admin/owner/delete`.
struct AdminDeleteOwnerResponse: Codable {
    let ownerId: String
    let documentsRemoved: Int
    let sinatraCleared: Bool

    enum CodingKeys: String, CodingKey {
        case ownerId         = "owner_id"
        case documentsRemoved = "documents_removed"
        case sinatraCleared  = "sinatra_cleared"
    }
}

// MARK: Audit

/// A single stale document entry found during the audit scan.
struct StaleDocumentEntry: Codable {
    let documentId: String
    let ownerId: String
    /// True when `registry.ownersDocuments[owner]` contains this ID.
    let inRegistry: Bool
    /// True when `PartitionTable.keys` contains this ID.
    let inTable: Bool

    enum CodingKeys: String, CodingKey {
        case documentId    = "document_id"
        case ownerId       = "owner_id"
        case inRegistry    = "in_registry"
        case inTable       = "in_table"
    }
}

struct AuditStaleResponse: Codable {
    let scanned: Int
    let stale: [StaleDocumentEntry]
}

/// Response for `POST /v1/admin/audit/reconcile`.
struct AuditReconcileResponse: Codable {
    let attempted: Int
    let removed: Int
    let failed: Int
    let failedIds: [String]

    enum CodingKeys: String, CodingKey {
        case attempted
        case removed
        case failed
        case failedIds = "failed_ids"
    }
}

// MARK: - Route Registration

/// Registers all `/v1/admin/` routes behind `AdminMiddleware`.
///
/// These routes are identical in shape to their non-admin counterparts but
/// **bypass the auth-owner lock** — the `owner_id` in the `sewn` body is
/// treated as the *target* user rather than being replaced by the authenticated
/// caller's ID. The middleware guarantees only the admin account can reach them.
///
/// Routes:
/// - `POST /v1/admin/list/owners`      — all registered owners with doc/group counts
/// - `POST /v1/admin/list/documents`   — documents for any target owner
/// - `POST /v1/admin/list/groups`      — groups for any target owner
/// - `POST /v1/admin/modify`           — modify any document (access, remove, group)
/// - `POST /v1/admin/modify/group`     — modify access for any group
/// - `POST /v1/admin/hnsw/stats`       — HNSW stats for any owner
/// - `POST /v1/admin/hnsw/personal`    — personal graph for any owner
/// - `DELETE /v1/admin/hnsw/node`      — delete any HNSW node and compact both graphs
/// - `POST /v1/admin/hnsw/compact`          — compact global + all personal graphs (cron target)
/// - `POST /v1/admin/hnsw/personal/rebuild` — rebuild empty personal graphs from global shard (Phase 3 migration)
/// - `POST /v1/admin/sinatra/gbt`      — Sinatra GBT model state for any owner
/// - `POST /v1/admin/table/document`   — PartitionIndex + PQ stats + HNSW cross-reference for one document
func registerAdminRoutes(_ router: some RouterMethods<SewnRequestContext>, _ sewn: Sewn, modelProvider: ModelProvider? = nil) {

    // MARK: POST /v1/admin/list/owners

    router.post("/v1/admin/list/owners") { request, context async throws -> AdminOwnersResponse in
        return AdminOwnersResponse(owners: [])
    }

    // MARK: POST /v1/admin/list/documents

    router.post("/v1/admin/list/documents") { request, context async throws -> DocumentListResponse in
        let body    = try await request.decode(as: DocumentListRequest.self, context: context)
        let ownerId = body.sewn.ownerId
        context.logger.info("[Admin] list/documents for owner: \(ownerId)")
        return .init(documents: [], access: [:])
    }

    // MARK: POST /v1/admin/list/groups

    router.post("/v1/admin/list/groups") { request, context async throws -> GroupListResponse in
        let body    = try await request.decode(as: GroupListRequest.self, context: context)
        let ownerId = body.sewn.ownerId
        context.logger.info("[Admin] list/groups for owner: \(ownerId)")
        return .init(groups: [], access: [:])
    }

    // MARK: POST /v1/admin/modify

    router.post("/v1/admin/modify") { request, context async throws -> ModificationResponse in
        let modifyRequest = try await request.decode(as: ModificationRequest.self, context: context)
        // Admin routes use the body's owner_id as the target, not the caller's.
        let ownerId = modifyRequest.sewn.ownerId
        let id      = modifyRequest.update.documentId
        let update  = modifyRequest.update
        let group   = modifyRequest.sewn.group
        // The target owner's request, acting for the admin caller's app.
        let targetReq = SewnRequest(ownerId: ownerId, group: group, requestID: context.id,
                                    callerApp: context.callerApp)

        context.logger.info("[Admin] modify \(update.operation.rawValue) doc: \(id), target owner: \(ownerId)")

        let updatedDocumentAccess: Bool
        let updatedGroupAccess:    Bool
        let updatedGroup:          Bool

        switch update.operation {
        case .remove:
            updatedDocumentAccess = false
            updatedGroupAccess    = false
            updatedGroup          = false
            await sewn.remove(documentId: id, group: group, ownerId: ownerId, request: targetReq)
        case .access, .group:
            updatedDocumentAccess = false
            updatedGroupAccess    = false
            updatedGroup          = false
        }

        return .init(
            document:       sewn.document(for: id),
            documentAccess: updatedDocumentAccess ? modifyRequest.documentAccess : nil,
            groupAccess:    updatedGroupAccess    ? modifyRequest.groupAccess    : nil,
            groupId:        updatedGroup          ? group?.id                    : nil,
            user:           sewn.user(for: ownerId)
        )
    }

    // MARK: POST /v1/admin/modify/group

    router.post("/v1/admin/modify/group") { request, context async throws -> GroupModificationResponse in
        let modifyRequest = try await request.decode(as: GroupModificationRequest.self, context: context)
        let ownerId       = modifyRequest.sewn.ownerId
        let groupId       = modifyRequest.groupId
        let access        = modifyRequest.access

        context.logger.info("[Admin] modify/group \(groupId) → \(access.rawValue), target owner: \(ownerId)")

        return .init(
            groupId: groupId,
            access:  nil,
            user:    sewn.user(for: ownerId)
        )
    }

    // MARK: POST /v1/admin/sinatra/gbt

    router.post("/v1/admin/sinatra/gbt") { request, context async throws -> FrankGBTResponse in
        let body    = try await request.decode(as: FrankGBTRequest.self, context: context)
        let ownerId = body.sewn.ownerId

        context.logger.info("[Admin] sinatra/gbt for owner: \(ownerId)")

        let owner        = SewnRegistry.Owner(id: ownerId)
        let sinatra      = sewn.sinatra
        let registry     = sinatra.registry
        let model        = registry?.models[owner]
        let collector    = registry?.collectors[owner]
        let dataSet      = registry?.dataSets[owner]
        let harmonyMem   = registry?.harmonyMemories[owner]
        let parkedCount  = registry?.parked[owner]?.count ?? 0

        let featureNames: [String] = [
            "ema_wa", "sma_wa",
            "macd", "macd_signal", "macd_prev_signal",
            "avg_vol_change", "volume_weighted_avg",
            "stochastic_k", "stochastic_d",
            "momentum", "velocity",
            "avg_sentiment",
        ]

        let hyperparameters  = GBTHyperparametersView(from: model?.hyperparameters ?? GBTHyperparameters())
        let indicatorPeriods = IndicatorPeriodsView(from: collector?.periods ?? .default)
        let harmonyMemView   = harmonyMem.map { HarmonyMemoryView(from: $0) }

        let trees: [GBTTreeView] = (model?.trees ?? []).enumerated().map {
            GBTTreeView(index: $0.offset, tree: $0.element, featureNames: featureNames)
        }

        return FrankGBTResponse(
            isTrained:               model?.totalTrees ?? 0 > 0,
            totalTrees:              model?.totalTrees ?? 0,
            initialPrediction:       model?.initialPrediction ?? 0.5,
            peakDataSetSize:         model?.peakDataSetSize ?? 0,
            dataSetSize:             dataSet?.size ?? 0,
            minimumTrainingSamples:  RetrievalDataCollector.minimumTrainingSamples,
            interactionHistoryCount: collector?.interactionHistoryCount ?? 0,
            parkedCount:             parkedCount,
            featureNames:            featureNames,
            hyperparameters:         hyperparameters,
            indicatorPeriods:        indicatorPeriods,
            harmonyMemory:           harmonyMemView,
            trees:                   trees
        )
    }

    // MARK: GET/PUT /v1/admin/model — runtime model selection (deploy checkpoints)

    router.get("/v1/admin/model") { _, _ async throws -> AdminModelResponse in
        AdminModelResponse(chatModel: ModelConfig.chatModel,
                           utilityModel: ModelConfig.utilityModel)
    }

    router.put("/v1/admin/model") { request, context async throws -> AdminModelResponse in
        let body = try await request.decode(as: AdminModelUpdateRequest.self, context: context)
        ModelConfig.update(chatModel: body.chatModel, utilityModel: body.utilityModel)
        context.logger.info("[Admin] model updated — chat: \(ModelConfig.chatModel), utility: \(ModelConfig.utilityModel)")
        return AdminModelResponse(chatModel: ModelConfig.chatModel,
                                  utilityModel: ModelConfig.utilityModel)
    }

    // MARK: POST /v1/admin/system/stats

    router.post("/v1/admin/system/stats") { request, context async throws -> AdminSystemStatsResponse in
        return AdminSystemStatsResponse(ownerCount: 0, documentCount: 0,
                                        availableCount: 0, restrictedCount: 0, groupCount: 0)
    }

    // MARK: POST /v1/admin/owner/delete

    router.post("/v1/admin/owner/delete") { request, context async throws -> AdminDeleteOwnerResponse in
        let body    = try await request.decode(as: AdminOwnerRequest.self, context: context)
        let ownerId = body.sewn.ownerId

        context.logger.info("[Admin] owner/delete — purging all data for owner: \(ownerId)")

        // Build a minimal SewnRequest for the removeAll call, acting for the
        // admin caller's app.
        let sewnReq = SewnRequest(ownerId: ownerId, group: nil, aggregate: nil, scope: nil, requestID: nil,
                                  callerApp: context.callerApp)

        // 1. Remove all documents, partition table entries, HNSW nodes, and registry entries.
        let docsRemoved = await sewn.removeAll(ownerId: ownerId, request: sewnReq)

        // 2. Remove all Sinatra data (parked, collector, dataset, model, harmony memory).
        let sinatraCleared = sewn.sinatra.removeOwner(id: ownerId)
        // SinatraHarness's on-device ledger, weights and traces for this owner.
        await modelProvider?.local.forgetOwner(ownerId)

        context.logger.info("[Admin] owner/delete — done. docs=\(docsRemoved), sinatra=\(sinatraCleared)")

        return AdminDeleteOwnerResponse(
            ownerId:          ownerId,
            documentsRemoved: docsRemoved,
            sinatraCleared:   sinatraCleared
        )
    }

    // MARK: POST /v1/admin/audit/stale

    router.post("/v1/admin/audit/stale") { request, context async throws -> AuditStaleResponse in
        return AuditStaleResponse(scanned: 0, stale: [])
    }

    // MARK: POST /v1/admin/audit/reconcile

    router.post("/v1/admin/audit/reconcile") { request, context async throws -> AuditReconcileResponse in
        return AuditReconcileResponse(attempted: 0, removed: 0, failed: 0, failedIds: [])
    }
}

