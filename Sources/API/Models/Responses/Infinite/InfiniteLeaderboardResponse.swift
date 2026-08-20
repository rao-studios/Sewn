//
//  InfiniteLeaderboardResponse.swift
//  seer-server
//

import Foundation


/// A single entry in the Infinite group leaderboard.
struct InfiniteGroupEntry: Codable {
    /// The public group — includes metadata, access, totalEarnings, and documents.
    let group: Seer.Group
    /// Composite score in [0, 1]. Derived from earnings, retrieval count, sentiment,
    /// and document count — normalized across all public groups at request time.
    let score: Double
    /// Aggregate retrieval count across all documents in this group.
    let retrievalCount: Int
    /// Aggregate average sentiment across all documents [0, 1].
    let averageSentiment: Double
    /// Most recent retrieval timestamp across all documents in the group.
    let lastActivity: Date?
    /// 1-indexed rank in the leaderboard. Ties share the same rank.
    let rank: Int

    enum CodingKeys: String, CodingKey {
        case group
        case score
        case retrievalCount   = "retrieval_count"
        case averageSentiment = "average_sentiment"
        case lastActivity     = "last_activity"
        case rank
    }
}

struct InfiniteLeaderboardResponse: Codable {
    var object: String = "list"
    let entries: [InfiniteGroupEntry]
    /// Total number of public groups (not just this page).
    let total: Int
    let page: Int
    let pageSize: Int

    enum CodingKeys: String, CodingKey {
        case object
        case entries
        case total
        case page
        case pageSize = "page_size"
    }
}
