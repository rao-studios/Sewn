//
//  Gita.Registry.swift
//  seer-server
//
//  Created by Ritesh Pakala on 4/13/26.
//

import Foundation

extension Gita {
    /// Economic registry for documents and partitions.
    ///
    /// **Market metaphor:** `Gita.Registry` is the stock market API. Each `Seer.Document`
    /// is a **security** listed on the network. `Sinatra` is the **prediction engine** that
    /// reads these market signals as features to forecast which securities will perform best
    /// in future retrievals.
    struct Registry: Codable {
        // MARK: - Storage

        /// Security listings keyed by document ID.
        /// Market metaphor: the exchange order book — one entry per listed security.
        var documentRecords: [DocumentID: DocumentRecord] = [:]

        /// Share profiles keyed by partition ID (content-addressed SHA-256 hash).
        /// Market metaphor: the lot registry — one entry per tradeable share.
        var partitionRecords: [String: PartitionRecord] = [:]

        // MARK: Init

        init() {}

        enum CodingKeys: String, CodingKey {
            case documentRecords  = "document_records"
            case partitionRecords = "partition_records"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            documentRecords  = try c.decodeIfPresent([DocumentID: DocumentRecord].self, forKey: .documentRecords)  ?? [:]
            partitionRecords = try c.decodeIfPresent([String: PartitionRecord].self,    forKey: .partitionRecords) ?? [:]
        }
    }
}

// MARK: - High-Performer Queries

extension Gita.Registry {
    /// Top N documents ranked by composite performance score, highest first.
    /// Market metaphor: the market leaderboard — the highest-priced securities on the exchange.
    func topDocuments(limit: Int = 10) -> [DocumentRecord] {
        Array(
            documentRecords.values
                .sorted { $0.performanceScore > $1.performanceScore }
                .prefix(limit)
        )
    }

    /// Top N partitions ranked by composite performance score, highest first.
    /// **Market metaphor:** the highest-yield shares across all listed securities.
    func topPartitions(limit: Int = 10) -> [PartitionRecord] {
        Array(
            partitionRecords.values
                .sorted { $0.performanceScore > $1.performanceScore }
                .prefix(limit)
        )
    }

    /// All document records for the given owner, sorted by performance score descending.
    /// Market metaphor: an owner's portfolio — their securities ranked by market value.
    func documents(forOwner ownerId: OwnerID) -> [DocumentRecord] {
        documentRecords.values
            .filter  { $0.ownerId == ownerId }
            .sorted  { $0.performanceScore > $1.performanceScore }
    }

    /// All partition records for the given document, sorted by performance score descending.
    /// Market metaphor: the share breakdown for a single security — its lots by yield score.
    func partitions(inDocument documentId: DocumentID) -> [PartitionRecord] {
        partitionRecords.values
            .filter  { $0.documentId == documentId }
            .sorted  { $0.performanceScore > $1.performanceScore }
    }

    /// Total credits earned across all documents tracked in this registry.
    /// Market metaphor: total market capitalization of the Gita exchange.
    var totalEarned: Gita.Credits {
        documentRecords.values.reduce(0.0) { $0 + $1.totalEarned }
    }
}

// MARK: - Accumulation

extension Gita.Registry {

    /// Merges one completed inference event into the registry.
    ///
    /// Market metaphor: records a completed trade — settling the credit earnings,
    /// updating each security's market weight, and syncing the latest sentiment data
    /// so Sinatra has fresh signals for its next prediction cycle.
    ///
    /// Call this within `case .inference:` in `Gita.track()` after
    /// `priceContribution(_:ledger:strategy:currentLoad:)` has run, so that
    /// per-owner `earning` values are populated in `contribution.owners`.
    ///
    /// - Parameters:
    ///   - contribution: Fully-priced `Gita.Contribution` with `earning` attached to each owner.
    ///   - retrievedPartitions: The partitions from `Gita.Payload.partitions`.
    ///   - documentStats: Current `Seer.DocumentStats` snapshot keyed by document ID,
    ///     typically sourced from `SeerRegistry.documentStats`.
    mutating func accumulate(
        contribution: Gita.Contribution,
        retrievedPartitions: [Seer.Partition],
        documentStats: [DocumentID: Seer.DocumentStats]
    ) {
        let partitionsByDocument = Dictionary(grouping: retrievedPartitions, by: \.documentId)
        let docEarnings = Self.earningsPerDocument(from: contribution)

        for owner in contribution.owners {
            for (documentId, influenceShare) in owner.influence {
                let docEarning    = docEarnings[documentId] ?? 0
                let royaltyWeight = owner.royalty * influenceShare

                // ── Document Record ────────────────────────────────────────────
                var docRecord = documentRecords[documentId] ?? DocumentRecord(
                    documentId:              documentId,
                    ownerId:                 owner.ownerId ?? owner.totemId,
                    totalEarned:             0,
                    inferenceCount:          0,
                    cumulativeRoyaltyWeight: 0,
                    retrievalCount:          0,
                    sentimentSum:            0,
                    lastRetrieved:           nil
                )
                docRecord.totalEarned             += docEarning
                docRecord.inferenceCount          += 1
                docRecord.cumulativeRoyaltyWeight += royaltyWeight
                // Mirror the latest cumulative performance stats from the Seer registry.
                // These are set rather than accumulated — DocumentStats is the source of truth.
                if let stats = documentStats[documentId] {
                    docRecord.retrievalCount = stats.retrievalCount
                    docRecord.sentimentSum   = stats.sentimentSum
                    if let t = stats.lastRetrieved { docRecord.lastRetrieved = t }
                }
                documentRecords[documentId] = docRecord

                // ── Partition Records ──────────────────────────────────────────
                let docPartitions = partitionsByDocument[documentId] ?? []
                guard !docPartitions.isEmpty else { continue }
                // Split document earnings evenly across all retrieved partitions for this event.
                let perPartitionEarning = docEarning / Double(docPartitions.count)

                for partition in docPartitions {
                    var partRecord = partitionRecords[partition.id] ?? PartitionRecord(
                        partitionId:    partition.id,
                        documentId:     documentId,
                        ownerId:        owner.ownerId ?? owner.totemId,
                        earnedCredits:  0,
                        retrievalCount: 0,
                        sentimentSum:   0,
                        lastRetrieved:  nil
                    )
                    partRecord.earnedCredits += perPartitionEarning
                    // Mirror the latest partition-level sentiment stats.
                    if let ps = documentStats[documentId]?.partitionSentiments[partition.id] {
                        partRecord.retrievalCount = ps.retrievalCount
                        partRecord.sentimentSum   = ps.sentimentSum
                        if let t = ps.lastRetrieved { partRecord.lastRetrieved = t }
                    }
                    partitionRecords[partition.id] = partRecord
                }
            }
        }
    }

    /// Distributes a priced contribution's earnings to each contributing document
    /// proportionally by `owner.royalty × owner.influence[documentId]`.
    /// 
    /// Market metaphor: post-trade settlement — allocating the proceeds of each
    /// inference to the securities that generated them.
    private static func earningsPerDocument(from contribution: Gita.Contribution) -> [DocumentID: Gita.Credits] {
        var result = [DocumentID: Gita.Credits]()
        for owner in contribution.owners where owner.earning > 0 {
            for (documentId, influence) in owner.influence {
                result[documentId, default: 0] += owner.earning * influence
            }
        }
        return result
    }
}

// MARK: Models

extension Gita.Registry {
    // MARK: - Document Economic Record
    struct DocumentRecord: Codable {
        var documentId: DocumentID
        var ownerId: OwnerID

        // MARK: Financial

        /// Total credits earned across all inference events where this document contributed.
        /// **Market metaphor:** cumulative revenue / total earnings for this security.
        var totalEarned: Gita.Credits

        /// Number of inference events this document appeared in.
        /// **Market metaphor:** trade volume — how many times this security has been traded.
        var inferenceCount: Int

        /// Cumulative royalty weight: sum of `owner.royalty × owner.influence[documentId]`
        /// across all inferences. Divide by `inferenceCount` for the average per-inference weight.
        /// **Market metaphor:** cumulative index weight — the security's running presence in the market.
        var cumulativeRoyaltyWeight: Double

        // MARK: Performance (mirrored from Seer.DocumentStats)

        /// Total retrieval count across all partitions. Synced from `Seer.DocumentStats`.
        var retrievalCount: Int

        /// Cumulative sentiment sum. Synced from `Seer.DocumentStats`.
        var sentimentSum: Double

        /// Timestamp of the most recent partition retrieval. Synced from `Seer.DocumentStats`.
        var lastRetrieved: Date?

        // MARK: Derived

        /// Average royalty contribution per inference event.
        /// **Market metaphor:** market share — the security's average weight in the retrieval index.
        var averageRoyaltyShare: Double {
            inferenceCount > 0 ? cumulativeRoyaltyWeight / Double(inferenceCount) : 0
        }

        /// Running average sentiment in [0, 1]. Neutral prior 0.5 before any retrievals.
        /// **Market metaphor:** analyst sentiment score — Sinatra reads this as the quality signal.
        var averageSentiment: Double {
            retrievalCount > 0 ? sentimentSum / Double(retrievalCount) : 0.5
        }

        /// Average credits earned per inference event.
        /// Market metaphor: earnings per trade (EPT) — revenue efficiency per transaction.
        var earningsPerInference: Gita.Credits {
            inferenceCount > 0 ? totalEarned / Double(inferenceCount) : 0
        }

        // TODO: Revisit the logic for performanceScoring.
        /// Composite performance score in [0, 1].
        ///
        /// Market metaphor: the security's current market price — a composite of quality,
        /// index weight, and earnings momentum. Sinatra uses this as a predictive feature.
        ///
        /// Weights:
        ///  - 40 % sentiment quality  (`averageSentiment`)
        ///  - 40 % royalty influence  (`averageRoyaltyShare`, capped at 1.0)
        ///  - 20 % earnings momentum  (`earningsPerInference`, ceiling 0.01 cr)
        var performanceScore: Double {
            let earningsCeiling: Gita.Credits = 0.01
            return (0.4 * averageSentiment)
                    + (0.4 * min(averageRoyaltyShare, 1.0))
                    + (0.2 * min(earningsPerInference / earningsCeiling, 1.0))
        }

        enum CodingKeys: String, CodingKey {
            case documentId              = "document_id"
            case ownerId                 = "owner_id"
            case totalEarned             = "total_earned"
            case inferenceCount          = "inference_count"
            case cumulativeRoyaltyWeight = "cumulative_royalty_weight"
            case retrievalCount          = "retrieval_count"
            case sentimentSum            = "sentiment_sum"
            case lastRetrieved           = "last_retrieved"
        }
    }

    // MARK: - Partition Economic Record

    /// Accumulated economic profile for a single content-addressed partition.
    ///
    /// Market metaphor: partitions are the **shares** of a document-security.
    /// Each unique "thought" (content chunk) is a lot — how it performs individually
    /// determines the dividend yield of the document it belongs to. High-yield shares
    /// are the specific passages that consistently drive retrieval value; Sinatra reads
    /// their `performanceScore` as a per-share signal when ranking a document's quality.
    ///
    /// Because partition IDs are SHA-256 hashes of their embedding vector, the
    /// same "thought" always maps to the same `PartitionRecord` regardless of
    /// which document version surfaced it.
    ///
    /// Credit earnings are computed as an even split of the owning document's
    /// per-inference earnings across all partitions retrieved in that event.
    struct PartitionRecord: Codable {
        var partitionId: String
        var documentId: DocumentID
        var ownerId: OwnerID

        // MARK: Financial

        /// Credits attributed to this partition across all inference events it appeared in.
        /// Market metaphor: cumulative dividend paid out to this share across all trades.
        var earnedCredits: Gita.Credits

        // MARK: Performance (mirrored from Seer.DocumentStats.PartitionSentiment)

        /// Number of times this partition was retrieved and scored.
        var retrievalCount: Int

        /// Cumulative sentiment sum. Synced from `Seer.DocumentStats.PartitionSentiment`.
        var sentimentSum: Double

        /// Timestamp of the most recent retrieval. Synced from `PartitionSentiment`.
        var lastRetrieved: Date?

        // MARK: Derived

        /// Running average sentiment in [0, 1]. Neutral prior 0.5 before any retrievals.
        /// **Market metaphor:** per-share analyst rating — Sinatra's quality signal for this lot.
        var averageSentiment: Double {
            retrievalCount > 0 ? sentimentSum / Double(retrievalCount) : 0.5
        }

        /// Average credits earned per retrieval event.
        /// Market metaphor: dividend yield — earnings efficiency per share retrieval.
        var earningsPerRetrieval: Gita.Credits {
            retrievalCount > 0 ? earnedCredits / Double(retrievalCount) : 0
        }

        /// Composite performance score in [0, 1].
        ///
        /// Market metaphor: the share's yield score — its quality and earnings efficiency
        /// combined into a single signal Sinatra can use for per-partition weighting.
        ///
        /// Weights:
        ///  - 60 % sentiment quality   (`averageSentiment`)
        ///  - 40 % earnings efficiency (`earningsPerRetrieval`, ceiling 0.001 cr)
        var performanceScore: Double {
            let earningsCeiling: Gita.Credits = 0.001
            return (0.6 * averageSentiment)
                    + (0.4 * min(earningsPerRetrieval / earningsCeiling, 1.0))
        }

        enum CodingKeys: String, CodingKey {
            case partitionId    = "partition_id"
            case documentId     = "document_id"
            case ownerId        = "owner_id"
            case earnedCredits  = "earned_credits"
            case retrievalCount = "retrieval_count"
            case sentimentSum   = "sentiment_sum"
            case lastRetrieved  = "last_retrieved"
        }
    }
}