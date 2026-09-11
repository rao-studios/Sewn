//
//  Sewn+Put.swift
//  swift-mlx-server
//
//  Created by Ritesh Pakala on 11/1/25.
//

import Foundation
import Logging

extension Sewn {
    struct BatchPutItem {
        let id: String
        let texts: [String]
        let tags: [String]
        let tagsEmbedding: [Float]?
        let mediaType: MediaType
        let update: SewnUpdate?
        let name: String?
        let metadata: Data?
    }
}

extension Sewn {
    /// Puts a new Sewn.Document into the database.
    func put(_ key: String, document: Sewn.Document) {
        let storage = FilePersistence(key: key,
                                      kind: .basic,
                                      logger: logger.base)
        storage.save(state: document)
    }

    /// Fans out to Thread for embedding and indexing.
    /// Retries up to 3 times with jittered exponential backoff when Thread signals
    /// backpressure (embedding queue full). If all retries fail, the batch is dropped
    /// and a warning is logged — once Thread auto-spawn is implemented (see TODO in
    /// fanoutIndex), a new node will become available before this point is reached.
    /// Thread is the source of truth — no local document persistence or registry writes.
    func putBatch(_ items: [BatchPutItem], request: SewnRequest) async {
        logger.info(
            "Put Batch",
            "Starting batch index (\(items.count) doc(s))",
            service: .embedding, request: request
        )

        guard _threadQueryClient != nil else {
            logger.warning("putBatch: no Thread connected — documents not indexed", service: .embedding, request: request)
            return
        }

        let maxAttempts = 3
        let baseNs: UInt64 = 500_000_000  // 500ms

        var placedThreadId: String? = nil
        for attempt in 0..<maxAttempts {
            let (ok, tid) = await fanoutIndex(items: items, request: request)
            if ok { placedThreadId = tid; break }

            guard attempt < maxAttempts - 1 else {
                logger.warning(
                    label: "Put Batch",
                    "Thread backpressure persisted after \(maxAttempts) attempt(s) — dropping \(items.count) item(s)",
                    service: .embedding, request: request
                )
                return
            }
            let jitter = UInt64.random(in: 0..<(baseNs / 4))
            let delay = (baseNs << attempt) + jitter
            logger.info(
                "Put Batch",
                "Backpressure on attempt \(attempt + 1) — retrying in \(delay / 1_000_000)ms",
                service: .embedding, request: request
            )
            try? await Task.sleep(nanoseconds: delay)
        }

        if let tid = placedThreadId, let uuid = UUID(uuidString: tid) {
            await nonisolatedRegistryMutator.recordOwnerThread(
                ownerId: request.ownerId,
                threadId: uuid
            )
        }

        let threadLabel = placedThreadId ?? "unknown"
        for item in items {
            logger.info(
                "Put Batch",
                "Sent to Thread \(threadLabel) (docId: \(item.id))",
                service: .embedding,
                request: request,
                flow: .embed(documentId: item.id)
            )
        }
    }
}
