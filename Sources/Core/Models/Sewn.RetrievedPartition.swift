//
//  Sewn.RetrievedPartition.swift
//  sewn-server
//
//  WHAT: One retrieved chunk and its rank signal — what the `local` provider hands
//        SinatraMLX, the only text its side model ever encodes.
//

import Foundation

extension Sewn {
    struct RetrievedPartition: Sendable, Equatable {
        let id: String
        let documentId: String
        let text: String
        /// Thread's PQ distance: lower is closer.
        let score: Float
        /// Document creation time. Thread search results do not carry it yet
        /// (`ThreadPartitionResult` has no created_at), so SinatraMLX falls back to the
        /// first time this owner retrieved the document.
        let createdAt: Date?

        /// De-duplicated, in retrieval order, with each partition's search score.
        static func from(_ partitions: [Sewn.Partition], scores: [String: Float]) -> [RetrievedPartition] {
            var seen = Set<String>()
            return partitions.compactMap { partition in
                guard seen.insert(partition.id).inserted else { return nil }
                return RetrievedPartition(
                    id: partition.id, documentId: partition.documentId, text: partition.text,
                    score: scores[partition.id] ?? 0, createdAt: nil)
            }
        }
    }
}
