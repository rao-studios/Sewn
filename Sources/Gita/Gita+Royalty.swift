//
//  Gita+Royalty.swift
//  seer-server
//
//  Created by Ritesh Pakala on 11/8/25.
//

import Foundation

// Patent #4: Royalty Calculation System
// TODO: [Weighted Influence] The royalty calculation currently derives influence purely from
// word count across retrieved partitions. In the future, influence should be weighted by
// document-level metrics surfaced through an enriched `Seer.Document` model. Planned factors:
//
//   • kind          — document class carries an inherent credibility/signal multiplier.
//                     e.g. research paper > article > social post (tweet, thread, etc.)
//                     A `Seer.Document.Kind` enum (or similar) should encode these tiers
//                     so the royalty function can apply a per-document kind multiplier
//                     before computing ownership percentages.
//
//   • retrievalCount — documents surfaced frequently across many distinct queries have
//                     demonstrated sustained relevance. A higher retrieval count should
//                     increase the document's weight, rewarding consistently useful content.
//                     `Seer.Document` will need to persist and expose this counter
//                     (e.g. via Supabase), updated atomically each time the document
//                     appears in a search result.
//
//   • recency / decay — optionally, weight can decay over time so that evergreen content
//                     stays competitive and older, less-retrieved documents taper off.
//
// Implementation notes:
//   - `royalty(for:request:)` will need a second parameter:
//       `documents: [DocumentID: Seer.Document]`
//     so per-document metadata is available during the weight calculation step.
//   - The weighted word count per document becomes:
//       rawWordCount * kindMultiplier * normalizedRetrievalWeight
//   - Weights should be normalized after applying multipliers so royalties still sum to 1.0.
//   - The `influence` dictionary per owner should reflect post-weighting values so callers
//     can inspect which documents drove the payout, not just raw text volume.

extension Gita {
    /// Calculate the royalty payouts.
    ///
    /// When `coOwners` contains entries for a document, that document's word-count
    /// contribution is split equally among all its owners. Documents absent from
    /// `coOwners` fall back to `partition.ownerId` (the original registrant), so
    /// passing an empty map reproduces the single-owner behaviour.
    ///
    /// - Parameters:
    ///   - partitions: Partitions retrieved for this inference.
    ///   - peerSources: Maps partitionId → OracleNodeID for peer-sourced partitions.
    ///   - coOwners: Maps documentId → all owner IDs for co-owned documents.
    ///               Only documents with 2+ owners need entries here.
    ///   - request: Request context for log correlation.
    /// - Returns: A `Gita.Contribution` with owner royalty shares (0.0–1.0).
    ///            Call `priceContribution(_:ledger:strategy:currentLoad:)` afterward
    ///            to attach credit earnings once token usage is known.
    func royalty(
        for partitions: [Seer.Partition],
        peerSources: [String: OracleNodeID] = [:],
        coOwners: [DocumentID: Set<OwnerID>] = [:],
        request: SeerRequest? = nil
    ) -> Gita.Contribution {
        guard !partitions.isEmpty else {
            return .init(owners: [])
        }

        // Single-pass: accumulate word counts per document across all partitions.
        // Done before the per-owner loop so counts are stable regardless of
        // iteration order and cannot be inflated across owner boundaries.
        var documentCounts = [DocumentID: Int]()
        for partition in partitions {
            documentCounts[partition.documentId, default: 0] += partition.text
                .components(separatedBy: .whitespacesAndNewlines)
                .count
        }

        let totalTextCount = documentCounts.values.reduce(0, +)
        guard totalTextCount > 0 else {
            return .init(owners: [])
        }

        // totemId string per partition (empty string for local/unknown partitions).
        let partitionTotemId: [String: String] = peerSources.mapValues { $0.uuidString }

        // Fallback map: for documents not in coOwners, attribute to the first partition's
        // (totemId, ownerId) pair. Empty ownerId strings are treated as nil (unauthenticated Totem).
        let partitionByDoc: [DocumentID: Seer.Partition] = partitions.reduce(into: [:]) {
            if $0[$1.documentId] == nil { $0[$1.documentId] = $1 }
        }

        // Split each document's word count equally among its owners.
        //
        // Grouping key: ownerId when available, otherwise totemId (unauthenticated Totem).
        // Each entry stores (totemId, ownerId?) alongside the per-document word-count share.
        //
        // TODO: [Weighted Split] Equal split is the baseline. Future: weight by each
        //       owner's upload date, retrieval count, or an explicit ownership stake
        //       stored in SeerRegistry — applying a per-owner multiplier before
        //       normalising so shares still sum to the document's total word count.
        var groupContrib: [String: (totemId: String, ownerId: String?, docs: [DocumentID: Double])] = [:]
        for (documentId, wordCount) in documentCounts {
            // Determine (totemId, ownerId) candidates for this document.
            let candidates: [(totemId: String, ownerId: String?)]
            if let coOwnerSet = coOwners[documentId], !coOwnerSet.isEmpty {
                // Co-owned by authenticated owners — attribute equally, using each owner's
                // totemId from the first matching partition (fallback to empty string).
                candidates = Array(coOwnerSet).map { owId in
                    let totemId = partitions
                        .first(where: { $0.documentId == documentId && $0.ownerId == owId })
                        .flatMap { partitionTotemId[$0.id] } ?? ""
                    return (totemId, owId)
                }
            } else if let p = partitionByDoc[documentId] {
                let totemId = partitionTotemId[p.id] ?? ""
                let ownerId = p.ownerId.isEmpty ? nil : p.ownerId
                candidates = [(totemId, ownerId)]
            } else {
                continue
            }
            let share = Double(wordCount) / Double(candidates.count)
            for (totemId, ownerId) in candidates {
                let key = ownerId ?? totemId
                if groupContrib[key] == nil {
                    groupContrib[key] = (totemId: totemId, ownerId: ownerId, docs: [:])
                }
                groupContrib[key]!.docs[documentId, default: 0] += share
            }
        }

        // Build one `Gita.Owner` per (totemId, ownerId) group.
        var gitaOwners = Set<Gita.Owner>()
        for (_, group) in groupContrib {
            let ownerTotal = group.docs.values.reduce(0, +)
            guard ownerTotal > 0 else { continue }
            let royalty   = ownerTotal / Double(totalTextCount)
            let influence = group.docs.mapValues { $0 / ownerTotal }
            gitaOwners.insert(.init(
                totemId: group.totemId,
                ownerId: group.ownerId,
                documentIds: Set(group.docs.keys),
                influence: influence,
                royalty: royalty
            ))
        }

        return .init(owners: gitaOwners)
    }
}

// MARK: - Credit Pricing

extension Gita {
    /// Computes per-document credit earnings from a fully priced `Gita.Contribution`.
    ///
    /// An owner's earning is distributed across their documents proportionally
    /// by `influence` — the share of the owner's retrieved word-count that each
    /// document contributed:
    ///
    /// ```
    /// documentEarning[docId] = owner.earning × owner.influence[docId]
    /// ```
    ///
    /// - Parameter contribution: A priced contribution (non-zero `earning` values).
    /// - Returns: A map of `DocumentID → Credits` ready to pass to
    ///   `RegistryMutator.accumulateEarnings(_:)`.
    func documentEarnings(from contribution: Gita.Contribution) -> [DocumentID: Credits] {
        var result = [DocumentID: Credits]()
        for owner in contribution.owners where owner.earning > 0 && owner.ownerId != contribution.spenderId {
            for (documentId, influence) in owner.influence {
                result[documentId, default: 0] += owner.earning * influence
            }
        }
        return result
    }

    /// Takes an attribution-only `Gita.Contribution` (royalty shares, no earnings)
    /// and returns a fully-priced copy with per-owner earnings, service charge, and
    /// total cost — all expressed in credits.
    ///
    /// Emits three structured log lines tagged `service: .gita, flow: .chat`:
    ///   - **Token Ledger** — per-call token counts and credit costs
    ///   - **Cost Breakdown** — LLM cost, service charge with surge info, total cost
    ///   - **Owner Payouts** — per-owner earning and royalty share
    ///
    /// - Parameters:
    ///   - contribution: The contribution from `royalty(for:)` — royalty shares only.
    ///   - ledger: Accumulated token usage for every LLM call in this request.
    ///   - strategy: How Seer prices its service on top of the LLM cost. Defaults to
    ///               the 20 % scaled fee with surge enabled.
    ///   - currentLoad: Number of concurrent requests on the server right now.
    ///                  Used by the surge pricing calculation.
    ///   - request: Optional request context for log correlation (requestId, ownerId).
    ///
    /// - Returns: A new `Gita.Contribution` satisfying:
    ///   `owners.map(\.earning).sum + serviceCharge == totalCost`
    func priceContribution(
        _ contribution: Gita.Contribution,
        ledger: TokenLedger,
        strategy: ServiceChargeStrategy = .default,
        currentLoad: Int = 1,
        request: SeerRequest? = nil
    ) -> Gita.Contribution {
        guard !ledger.isEmpty else { return contribution }

        let llmCost       = ledger.totalCredits
        let serviceCharge = strategy.charge(llmCost: llmCost, currentLoad: currentLoad)
        let totalCost     = llmCost + serviceCharge
        let surge         = strategy.surgeMultiplier(currentLoad: currentLoad)

        // Distribute the raw LLM cost proportionally across owners by royalty share.
        // `earning` sums to exactly `llmCost`; the service charge sits on top.
        //
        // Because Set hashing is keyed on the owner identity, we rebuild into a
        // dictionary first to safely update each owner, then re-insert into a fresh Set.
        var ownersById = Dictionary(uniqueKeysWithValues: contribution.owners.map { ($0.identityKey, $0) })
        for id in ownersById.keys {
            let royalty = ownersById[id]?.royalty ?? 0
            ownersById[id]?.earning = llmCost * royalty
        }

        let pricedOwners = Set(ownersById.values)
        let totalPayout  = pricedOwners.reduce(0.0) { $0 + $1.earning }

        let priced = Gita.Contribution(
            owners: pricedOwners,
            totalPayout: totalPayout,
            serviceCharge: serviceCharge,
            totalCost: totalCost,
            ledger: ledger,
            spenderId: request?.ownerId
        )

        logPricing(
            ledger: ledger,
            llmCost: llmCost,
            serviceCharge: serviceCharge,
            totalCost: totalCost,
            surge: surge,
            strategy: strategy,
            pricedOwners: pricedOwners,
            totalPayout: totalPayout,
            request: request
        )

        return priced
    }

    // MARK: - Pricing Log

    private func logPricing(
        ledger: TokenLedger,
        llmCost: Credits,
        serviceCharge: Credits,
        totalCost: Credits,
        surge: Double,
        strategy: ServiceChargeStrategy,
        pricedOwners: Set<Gita.Owner>,
        totalPayout: Credits,
        request: SeerRequest?
    ) {
        // ── Token Ledger ──────────────────────────────────────────────────────
        var ledgerLog = "Token Ledger (\(ledger.lines.count) call\(ledger.lines.count == 1 ? "" : "s")):\n"
        for line in ledger.lines {
            ledgerLog += "  [\(line.model.padding(toLength: 20, withPad: " ", startingAt: 0))]"
            ledgerLog += "  prompt=\(String(line.promptTokens).padding(toLength: 6, withPad: " ", startingAt: 0))"
            ledgerLog += "  completion=\(String(line.completionTokens).padding(toLength: 6, withPad: " ", startingAt: 0))"
            ledgerLog += "  →  \(CreditConversion.formattedCredits(line.credits))"
            ledgerLog += "  (\(CreditConversion.formattedDollars(line.credits)))\n"
        }
        ledgerLog += "  \(String(repeating: "─", count: 53))\n"
        ledgerLog += "  Total  \(ledger.totalTokens) tokens"
        ledgerLog += "  →  \(CreditConversion.formattedCredits(llmCost))"
        ledgerLog += "  (\(CreditConversion.formattedDollars(llmCost)))"
        logger.info("Token Ledger", "\n\(ledgerLog)", service: .gita, request: request, flow: .chat)

        // ── Cost Breakdown ────────────────────────────────────────────────────
        let surgeLabel = String(format: "%.2f× surge", surge)
        let rateLabel  = "\(strategy.baseRateDescription) × \(surgeLabel)"
        var costLog    = "Cost Breakdown:\n"
        costLog += "  LLM Cost      :  \(CreditConversion.formattedCredits(llmCost).padding(toLength: 12, withPad: " ", startingAt: 0))"
        costLog += "  (\(CreditConversion.formattedDollars(llmCost)))\n"
        costLog += "  Service Charge:  \(CreditConversion.formattedCredits(serviceCharge).padding(toLength: 12, withPad: " ", startingAt: 0))"
        costLog += "  (\(CreditConversion.formattedDollars(serviceCharge)))  [\(rateLabel)]\n"
        costLog += "  \(String(repeating: "─", count: 53))\n"
        costLog += "  Total Cost    :  \(CreditConversion.formattedCredits(totalCost).padding(toLength: 12, withPad: " ", startingAt: 0))"
        costLog += "  (\(CreditConversion.formattedDollars(totalCost)))"
        logger.info("Cost Breakdown", "\n\(costLog)", service: .gita, request: request, flow: .chat)

        // ── Owner Payouts ─────────────────────────────────────────────────────
        let sortedOwners = pricedOwners.sorted { $0.earning > $1.earning }
        var payoutLog    = "Owner Payouts (\(sortedOwners.count) owner\(sortedOwners.count == 1 ? "" : "s")):\n"
        for owner in sortedOwners {
            payoutLog += "  \((owner.ownerId ?? owner.totemId).padding(toLength: 30, withPad: " ", startingAt: 0))"
            payoutLog += String(format: "  %5.2f%%", owner.royalty * 100)
            payoutLog += "  →  \(CreditConversion.formattedCredits(owner.earning).padding(toLength: 12, withPad: " ", startingAt: 0))"
            payoutLog += "  (\(CreditConversion.formattedDollars(owner.earning)))\n"
        }
        payoutLog += "  \(String(repeating: "─", count: 53))\n"
        payoutLog += "  Total Payout  :  \(CreditConversion.formattedCredits(totalPayout).padding(toLength: 12, withPad: " ", startingAt: 0))"
        payoutLog += "  (\(CreditConversion.formattedDollars(totalPayout)))"
        logger.info("Owner Payouts", "\n\(payoutLog)", service: .gita, request: request, flow: .chat)
    }
}
