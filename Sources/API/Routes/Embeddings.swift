//
//  BatchEmbeddings.swift
//  sewn-server
//
//  Created by Ritesh Pakala Rao on 12/10/25.
//

import Foundation
import Hummingbird
import Metrics

func registerEmbeddingsRoute(
    _ router: some RouterMethods<SewnRequestContext>,
    _ sewn: Sewn,
    modelProvider: ModelProvider
) {
    router.post("/v1/embeddings") { request, context async throws -> EmbeddingResponse in
        let embeddingRequest = try await request.decode(as: EmbeddingRequest.self, context: context)
        let sewnReq = try embeddingRequest.sewn.from(context)
        let logger = sewn.logger
        let embeddingReqId = "emb-\(UUID().uuidString)"
        let modelName = "mistral-embed"

        logger.info(
            "Batch Embedding",
            "Received batch embedding request (ID: \(embeddingReqId)) | group: \(embeddingRequest.sewn.group?.id ?? "") | ip: \(context.remoteAddress?.ipAddress ?? "unknown")",
            service: .embedding
        )

        let inputs = embeddingRequest.inputs

        Counter(label: "sewn.batch.documents_total", dimensions: [("state", "received")])
            .increment(by: inputs.count)

        // Sanitize inputs and build BatchPutItems — dedup is handled by Thread.
        var batchItems: [Sewn.BatchPutItem] = []
        var failedCount = 0

        for (idx, input) in inputs.enumerated() {
            let values: [String] = input.values.filter { !$0.isEmpty }
            let texts: [String]
            if embeddingRequest.sanitize == true {
                texts = TextChunker.chunk(values)
                logger.info("Batch Embedding", "Input[\(idx)] chunked into \(texts.count) segment(s)", service: .embedding)
            } else {
                texts = values
            }

            guard !texts.isEmpty, texts.allSatisfy({ !$0.isEmpty }) else {
                logger.info(
                    "Batch Embedding",
                    "⚠️ Dropping input[\(idx)] — all text values are empty (ID: \(embeddingReqId))",
                    service: .embedding
                )
                failedCount += 1
                continue
            }

            let documentId = sewn.computeHash(from: texts)
            let docTags = embeddingRequest.tags?[idx] ?? []
            let allTags = docTags.isEmpty ? TagGenerator.generate(from: texts) : docTags
            let docName: String? = {
                guard let names = embeddingRequest.names, idx < names.count,
                      !names[idx].isEmpty else { return nil }
                return names[idx]
            }()
            let docMetadata: Data? = {
                guard let metadata = embeddingRequest.metadata, idx < metadata.count else { return nil }
                return metadata[idx]
            }()

            batchItems.append(Sewn.BatchPutItem(
                id: documentId,
                texts: texts,
                tags: allTags,
                tagsEmbedding: [Float]?.none,
                mediaType: embeddingRequest.mediaType ?? .text,
                update: embeddingRequest.update,
                name: docName,
                metadata: docMetadata
            ))
        }

        // Enrich group with merged tags before fan-out.
        let enrichedReq: SewnRequest = {
            guard var g = sewnReq.group, !batchItems.isEmpty else { return sewnReq }
            let existingTags = g.metadata?.tags ?? []
            let newTags = batchItems.flatMap(\.tags)
            let merged = Array(Set(existingTags + newTags)).sorted()
            guard !merged.isEmpty else { return sewnReq }
            var meta = g.metadata ?? Sewn.Group.Metadata()
            meta.tags = merged
            g.metadata = meta
            return SewnRequest(ownerId: sewnReq.ownerId, group: g,
                               groups: sewnReq.groups, tags: sewnReq.tags,
                               aggregate: sewnReq.aggregate, scope: sewnReq.scope,
                               requestID: sewnReq.requestID)
        }()

        if !batchItems.isEmpty {
            for item in batchItems {
                logger.info(
                    "Batch Embedding",
                    "Enqueuing for Thread index (docId: \(item.id))",
                    service: .embedding,
                    flow: .embed(documentId: item.id)
                )
            }
            Counter(label: "sewn.batch.documents_total", dimensions: [("state", "prepared")])
                .increment(by: batchItems.count)
            await sewn.enqueuePut(batchItems, request: enrichedReq)
        }

        if failedCount > 0 {
            Counter(label: "sewn.batch.documents_total", dimensions: [("state", "failed")])
                .increment(by: failedCount)
        }

        let success = failedCount == 0

        return EmbeddingResponse(
            model: modelName,
            usage: .empty,
            success: success,
            user: sewn.user(for: sewnReq.ownerId)
        )
    }
}
