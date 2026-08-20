import Foundation

extension Seer {
    nonisolated var registry: SeerRegistry? { registryMutator.snapshot }

    // MARK: - Billing

    /// Fire-and-forget: merges per-document performance updates into the billing stats map.
    nonisolated func accumulatePerformance(_ updates: [DocumentID: Seer.DocumentStats]) {
        guard !updates.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.registryMutator.accumulatePerformance(updates)
        }
    }

    /// Fire-and-forget: accumulates per-document credit earnings.
    nonisolated func accumulateEarnings(from contribution: Gita.Contribution, totemIds: [String] = []) {
        guard contribution.totalCost > 0 else { return }

        let earnings = gita.documentEarnings(from: contribution)
        if !earnings.isEmpty {
            Task { [weak self] in
                guard let self else { return }
                await self.registryMutator.accumulateEarnings(earnings)
            }
        }

        if let spenderId = contribution.spenderId {
            let exchange = Gita.CreditExchange(contribution: contribution, totemIds: totemIds)
            gita.recordExchange(exchange, spenderId: spenderId)
        }
    }

    // MARK: - Stats

    func stats(for documentId: DocumentID) -> Seer.DocumentStats? {
        registry?.documentStats[documentId]
    }
}
