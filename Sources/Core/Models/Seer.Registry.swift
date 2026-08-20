import Foundation

typealias DocumentID = String
typealias GroupID = String
typealias OwnerID = String

/// Lean billing-only registry. Document/group/ownership data lives on Totem nodes.
struct SeerRegistry: Codable {
    // Billing and engagement stats per document.
    // Keyed by DocumentID — same identifier as the document itself.
    var documentStats: [DocumentID : Seer.DocumentStats] = [:]
    // Owner IDs that have opted in to Marielle bridging.
    var bridgingEnabledOwners: Set<OwnerID> = []

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case documentStats
        case bridgingEnabledOwners
    }

    /// Tolerant decoder: ignores all legacy fields (ownersDocuments, groups, etc.)
    /// that existed before Totem became the source of truth. Old serialised registries
    /// won't crash on decode — the large fields are simply skipped.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        documentStats         = try c.decodeIfPresent([DocumentID: Seer.DocumentStats].self, forKey: .documentStats)       ?? [:]
        bridgingEnabledOwners = try c.decodeIfPresent(Set<OwnerID>.self,                     forKey: .bridgingEnabledOwners) ?? []
    }

    init() {}
}

// MARK: - Marielle

extension SeerRegistry {
    func bridgingEnabled(for ownerId: OwnerID) -> Bool {
        bridgingEnabledOwners.contains(ownerId)
    }

    mutating func enableBridging(for ownerId: OwnerID) {
        bridgingEnabledOwners.insert(ownerId)
    }

    mutating func disableBridging(for ownerId: OwnerID) {
        bridgingEnabledOwners.remove(ownerId)
    }
}

// MARK: - Document Stats

extension SeerRegistry {
    func stats(for documentId: DocumentID) -> Seer.DocumentStats {
        documentStats[documentId] ?? .init(id: documentId)
    }

    mutating func addEarnings(_ earnings: [DocumentID: Gita.Credits]) {
        for (documentId, credits) in earnings where credits > 0 {
            documentStats[documentId, default: .init(id: documentId)].totalEarned += credits
        }
    }

    mutating func addPerformance(_ updates: [DocumentID: Seer.DocumentStats]) {
        for (documentId, updated) in updates {
            var entry = documentStats[documentId, default: .init(id: documentId)]
            entry.retrievalCount += updated.retrievalCount
            entry.sentimentSum   += updated.sentimentSum
            if let t = updated.lastRetrieved {
                entry.lastRetrieved = t
            }
            for (partitionId, count) in updated.partitionRetrievalCount {
                entry.partitionRetrievalCount[partitionId, default: 0] += count
            }
            for (partitionId, ps) in updated.partitionSentiments {
                entry.partitionSentiments[partitionId, default: .init()].retrievalCount += ps.retrievalCount
                entry.partitionSentiments[partitionId, default: .init()].sentimentSum   += ps.sentimentSum
                if let t = ps.lastRetrieved {
                    entry.partitionSentiments[partitionId, default: .init()].lastRetrieved = t
                }
            }
            documentStats[documentId] = entry
        }
    }
}

// MARK: - Access (kept for Modify route return types and Seer.Group model)

extension SeerRegistry {
    enum Access: String, Codable {
        case available
        case restricted
        case unknown
    }
}

// MARK: - Owner (keyed Sinatra ML registries; does not represent document ownership)

extension SeerRegistry {
    struct Owner: Codable, Hashable {
        let id: OwnerID
    }
}
