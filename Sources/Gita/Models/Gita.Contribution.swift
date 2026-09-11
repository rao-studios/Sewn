//
//  Gita.Royalty.swift
//  sewn-server
//
//  Created by Ritesh Pakala on 11/8/25.
//

import Foundation

/// Identifies a peer node that served search results. Kept as UUID for
/// compatibility with Gita's royalty attribution after Oracle removal.
typealias OracleNodeID = UUID

extension Gita {
    /// A serialisable character-offset range into the LLM response string.
    /// Reconstruct a `Range<String.Index>` on the client with:
    ///   `text.index(text.startIndex, offsetBy: span.lower) ..< text.index(text.startIndex, offsetBy: span.upper)`
    struct TextSpan: Codable, Equatable {
        let lower: Int
        let upper: Int
    }

    struct Contribution: Codable {
        var owners: Set<Owner>

        // MARK: - Cost Distribution

        /// Sum of all owner earnings for this inference (in credits).
        /// Equals the raw LLM token cost distributed proportionally via royalty shares.
        var totalPayout: Credits

        /// Sewn's service charge for this inference (in credits).
        /// Covers vector search, Gita computation, peer coordination, and infrastructure.
        ///
        /// Invariant: `totalPayout + serviceCharge == totalCost`
        var serviceCharge: Credits

        /// Total credit cost charged to the requester for this inference.
        /// `totalCost = totalPayout + serviceCharge`
        var totalCost: Credits

        /// Full token ledger for this request — all LLM calls and their individual costs.
        var ledger: TokenLedger?

        /// The owner ID of the user who made this inference request (the credit spender).
        var spenderId: OwnerID?

        // MARK: - Init

        init(
            owners: Set<Owner>,
            totalPayout: Credits = 0,
            serviceCharge: Credits = 0,
            totalCost: Credits = 0,
            ledger: TokenLedger? = nil,
            spenderId: OwnerID? = nil
        ) {
            self.owners = owners
            self.totalPayout = totalPayout
            self.serviceCharge = serviceCharge
            self.totalCost = totalCost
            self.ledger = ledger
            self.spenderId = spenderId
        }

        // MARK: - Debug

        var debugDescription: String {
            var desc = "Royalty Distribution:\n"
            for owner in owners.sorted(by: { $0.royalty > $1.royalty }) {
                desc += "  - \(owner.ownerId ?? owner.threadId): \(String(format: "%.2f", owner.royalty * 100))%"
                if owner.earning > 0 {
                    desc += "  earning=\(CreditConversion.formattedCredits(owner.earning))"
                    desc += " (\(CreditConversion.formattedDollars(owner.earning)))"
                }
                desc += "\n"
                for (documentId, influence) in owner.influence {
                    desc += "    - \(documentId): \(String(format: "%.2f", influence * 100.0))%\n"
                }
            }
            if totalCost > 0 {
                desc += "  ─────────────────────────────────────────\n"
                desc += "  Owner Payouts : \(CreditConversion.formattedCredits(totalPayout))"
                desc += " (\(CreditConversion.formattedDollars(totalPayout)))\n"
                desc += "  Service Charge: \(CreditConversion.formattedCredits(serviceCharge))"
                desc += " (\(CreditConversion.formattedDollars(serviceCharge)))\n"
                desc += "  Total Cost    : \(CreditConversion.formattedCredits(totalCost))"
                desc += " (\(CreditConversion.formattedDollars(totalCost)))\n"
            }
            return desc
        }

        var ownersDebugDescription: String {
            var desc = "Royalty Distribution:\n"
            for owner in owners.sorted(by: { $0.royalty > $1.royalty }) {
                desc += "  - \(owner.ownerId ?? owner.threadId): \(String(format: "%.2f", owner.royalty * 100))%"
                if owner.earning > 0 {
                    desc += "  (\(CreditConversion.formattedCredits(owner.earning)))"
                }
                desc += "\n"
            }
            return desc
        }

        enum CodingKeys: String, CodingKey {
            case owners
            case totalPayout   = "total_payout"
            case serviceCharge = "service_charge"
            case totalCost     = "total_cost"
            case ledger
            case spenderId     = "spender_id"
        }
    }

    struct Owner: Codable, Hashable {
        /// The Thread that sourced these partitions — always present.
        var threadId: String
        /// Authenticated owner identity. `nil` when the Thread has no registered owner;
        /// linked to `threadId` later when the owner claims their Thread's earnings.
        var ownerId: String?
        var documentIds: Set<String>
        var influence: [DocumentID: Double]
        var royalty: Double
        /// Character-offset ranges in the LLM response text that are attributed to
        /// this owner's retrieved content. Empty until span computation runs.
        var spans: [Gita.TextSpan]
        /// Exact per-source-file attribution: spans keyed by the Thread document
        /// they were drawn from. Populated only by the citation-marker path
        /// (`Gita.annotate`) — nil when spans came from the heuristic alone.
        var documentSpans: [DocumentID: [Gita.TextSpan]]?
        /// Credit amount earned by this owner for this inference.
        /// Computed as `royalty × llmCost` once a `TokenLedger` is priced in.
        /// Zero until `Gita.priceContribution(_:ledger:strategy:currentLoad:)` runs.
        var earning: Credits

        init(
            threadId: String,
            ownerId: String? = nil,
            documentIds: Set<String>,
            influence: [DocumentID: Double],
            royalty: Double,
            spans: [Gita.TextSpan] = [],
            documentSpans: [DocumentID: [Gita.TextSpan]]? = nil,
            earning: Credits = 0
        ) {
            self.threadId = threadId
            self.ownerId = ownerId
            self.documentIds = documentIds
            self.influence = influence
            self.royalty = royalty
            self.spans = spans
            self.documentSpans = documentSpans
            self.earning = earning
        }

        enum CodingKeys: String, CodingKey {
            case threadId     = "thread_id"
            case ownerId     = "owner_id"
            case documentIds = "document_ids"
            case influence
            case royalty
            case spans
            case documentSpans = "document_spans"
            case earning
        }

        /// Stable identity key: one owner per (thread, authenticated owner) pair.
        /// Keying on threadId alone would merge distinct owners whose documents
        /// live on the same Thread (or all local owners, threadId == "").
        var identityKey: String { "\(threadId)|\(ownerId ?? "")" }

        func hash(into hasher: inout Hasher) {
            hasher.combine(threadId)
            hasher.combine(ownerId)
        }

        static func == (lhs: Owner, rhs: Owner) -> Bool {
            lhs.threadId == rhs.threadId && lhs.ownerId == rhs.ownerId
        }
    }
}
