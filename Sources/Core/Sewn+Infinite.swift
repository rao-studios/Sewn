//
//  Sewn+Infinite.swift
//  sewn-server
//

import Foundation

// MARK: - Internal metrics type

extension Sewn {
    struct GroupMetrics {
        let totalEarnings: Gita.Credits
        let retrievalCount: Int
        let sentimentSum: Double
        let documentCount: Int
        let lastActivity: Date?

        var averageSentiment: Double {
            retrievalCount > 0 ? sentimentSum / Double(retrievalCount) : 0.5
        }
    }
}

// MARK: - Public interface

extension Sewn {

    /// Returns a paginated, ranked leaderboard of all public (`.available`) groups.
    ///
    /// Groups are sourced from Thread via `fanoutLibrary`; billing metrics come from
    /// the local `documentStats` registry. Ranking uses a weighted, min-max normalised
    /// composite score: 40% earnings, 30% retrievals, 20% sentiment, 10% doc count.
    nonisolated func leaderboard(page: Int = 1, pageSize: Int = 20) async -> (entries: [InfiniteGroupEntry], total: Int) {
        let (allGroups, _, _) = await fanoutLibrary(ownerId: "")
        let publicGroups = allGroups.filter { $0.access == .available }
        guard !publicGroups.isEmpty else { return ([], 0) }

        let docStats = registry?.documentStats ?? [:]

        let rawMetrics: [(group: Sewn.Group, metrics: GroupMetrics)] = publicGroups.map { group in
            var totalEarnings: Gita.Credits = 0
            var totalRetrievalCount = 0
            var totalSentimentSum = 0.0
            var latestActivity: Date? = nil
            for doc in group.documents {
                let stats = docStats[doc.id]
                totalEarnings       += stats?.totalEarned    ?? 0
                totalRetrievalCount += stats?.retrievalCount ?? 0
                totalSentimentSum   += stats?.sentimentSum   ?? 0.0
                if let t = stats?.lastRetrieved {
                    latestActivity = latestActivity.map { max($0, t) } ?? t
                }
            }
            return (
                group: group,
                metrics: GroupMetrics(
                    totalEarnings:  totalEarnings,
                    retrievalCount: totalRetrievalCount,
                    sentimentSum:   totalSentimentSum,
                    documentCount:  group.documents.count,
                    lastActivity:   latestActivity
                )
            )
        }

        // Min-max normalize each metric across all public groups.
        let earnings   = rawMetrics.map { Double($0.metrics.totalEarnings) }
        let retrievals = rawMetrics.map { Double($0.metrics.retrievalCount) }
        let sentiments = rawMetrics.map { $0.metrics.averageSentiment }
        let docCounts  = rawMetrics.map { Double($0.metrics.documentCount) }

        func minMax(_ values: [Double]) -> (min: Double, max: Double) {
            (values.min() ?? 0, values.max() ?? 0)
        }
        func normalize(_ value: Double, range: (min: Double, max: Double)) -> Double {
            let span = range.max - range.min
            guard span > 0 else { return 0 }
            return (value - range.min) / span
        }

        let earningsRange  = minMax(earnings)
        let retrievalRange = minMax(retrievals)
        let sentimentRange = minMax(sentiments)
        let docCountRange  = minMax(docCounts)

        var scored: [(group: Sewn.Group, score: Double, metrics: GroupMetrics)] = rawMetrics.map { item in
            let score =
                0.40 * normalize(Double(item.metrics.totalEarnings), range: earningsRange)
              + 0.30 * normalize(Double(item.metrics.retrievalCount), range: retrievalRange)
              + 0.20 * normalize(item.metrics.averageSentiment,        range: sentimentRange)
              + 0.10 * normalize(Double(item.metrics.documentCount),   range: docCountRange)
            return (group: item.group, score: score, metrics: item.metrics)
        }
        scored.sort { $0.score > $1.score }

        let total = scored.count
        let clampedPage     = max(1, page)
        let clampedPageSize = max(1, min(100, pageSize))
        let startIdx = (clampedPage - 1) * clampedPageSize
        guard startIdx < total else { return ([], total) }
        let pageSlice = scored[startIdx ..< min(startIdx + clampedPageSize, total)]

        var rank = startIdx + 1
        var prevScore: Double? = nil
        var prevRank = rank

        var entries: [InfiniteGroupEntry] = []
        for (offset, item) in pageSlice.enumerated() {
            let absIdx = startIdx + offset
            if let prev = prevScore, prev == item.score {
                rank = prevRank
            } else {
                rank = absIdx + 1
                prevRank = rank
            }
            prevScore = item.score

            var group = item.group
            group.totalEarnings = item.group.documents
                .reduce(Gita.Credits(0)) { $0 + (docStats[$1.id]?.totalEarned ?? 0) }

            entries.append(InfiniteGroupEntry(
                group:            group,
                score:            item.score,
                retrievalCount:   item.metrics.retrievalCount,
                averageSentiment: item.metrics.averageSentiment,
                lastActivity:     item.metrics.lastActivity,
                rank:             rank
            ))
        }

        return (entries, total)
    }

    /// Returns public groups whose label, description, or tags match `query`.
    /// Results are sorted by descending activity score. `limit` is clamped to [1, 100].
    nonisolated func searchGroups(query: String, limit: Int = 20) async -> [Sewn.Group] {
        guard !query.isEmpty else { return [] }
        let clampedLimit = max(1, min(100, limit))

        let (allGroups, _, _) = await fanoutLibrary(ownerId: "")
        let publicGroups = allGroups.filter { $0.access == .available }

        let docStats = registry?.documentStats ?? [:]

        var matched: [(group: Sewn.Group, score: Double)] = []
        for group in publicGroups {
            let matches =
                group.label.localizedCaseInsensitiveContains(query) ||
                (group.metadata?.description?.localizedCaseInsensitiveContains(query) == true) ||
                (group.metadata?.tags.contains { $0.localizedCaseInsensitiveCompare(query) == .orderedSame } == true)
            guard matches else { continue }

            let retrievalCount = group.documents.reduce(0) { $0 + (docStats[$1.id]?.retrievalCount ?? 0) }
            let totalEarnings  = group.documents.reduce(Gita.Credits(0)) { $0 + (docStats[$1.id]?.totalEarned ?? 0) }
            let score = Double(totalEarnings) + Double(retrievalCount) * 0.5
            matched.append((group: group, score: score))
        }

        matched.sort { $0.score > $1.score }
        return matched.prefix(clampedLimit).map(\.group)
    }
}
