import Foundation

extension Sewn {
    nonisolated var registry: SewnRegistry? { registryMutator.snapshot }

    // MARK: - Billing

    /// Fire-and-forget: merges per-document performance updates into the billing stats map.
    nonisolated func accumulatePerformance(_ updates: [DocumentID: Sewn.DocumentStats]) {
        guard !updates.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.registryMutator.accumulatePerformance(updates)
        }
    }

    /// Fire-and-forget: accumulates per-document credit earnings.
    nonisolated func accumulateEarnings(from contribution: Gita.Contribution, threadIds: [String] = []) {
        guard contribution.totalCost > 0 else { return }

        let earnings = gita.documentEarnings(from: contribution)
        if !earnings.isEmpty {
            Task { [weak self] in
                guard let self else { return }
                await self.registryMutator.accumulateEarnings(earnings)
            }
        }

        if let spenderId = contribution.spenderId {
            let exchange = Gita.CreditExchange(contribution: contribution, threadIds: threadIds)
            gita.recordExchange(exchange, spenderId: spenderId)
        }
    }

    // MARK: - Stats

    func stats(for documentId: DocumentID) -> Sewn.DocumentStats? {
        registry?.documentStats[documentId]
    }
}
