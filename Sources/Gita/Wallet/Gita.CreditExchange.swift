//
//  Gita.CreditExchange.swift
//  sewn-server
//
//  Created by Ritesh Pakala on 4/23/26.
//

import Foundation

extension Gita {
    /// Record of a single inference credit exchange: one spender dispersing credits
    /// to one or more document owners proportional to their royalty shares.
    struct CreditExchange: Codable, Sendable {
        let id: String
        let timestamp: Date
        let documentIds: Set<String>
        let totalCost: Credits
        let serviceCharge: Credits
        /// Credits paid to each contributing owner, broken down by document ID.
        /// Self-referential owners appear with zeroed values (no circular credit).
        let payouts: [OwnerID: [DocumentID: Credits]]
        /// The actual amount deducted from the spender's wallet: owner payouts (self-earnings
        /// already zeroed) plus the service charge. Equals totalCost when no self-referential.
        /// Invariant: netCost + selfReferentialSavings == totalCost
        let netCost: Credits
        /// Credits the spender would have paid to others had they not owned the retrieved
        /// documents themselves. Zero when there is no self-referential overlap.
        /// Invariant: netCost + selfReferentialSavings == totalCost
        let selfReferentialSavings: Credits
        let threadIds: [String]

        init(contribution: Gita.Contribution, threadIds: [String] = [], timestamp: Date = Date()) {
            self.id = UUID().uuidString
            self.timestamp = timestamp
            self.documentIds = contribution.owners.reduce(into: Set<String>()) { $0.formUnion($1.documentIds) }
            self.serviceCharge = contribution.serviceCharge
            self.threadIds = threadIds
            var payouts = [OwnerID: [DocumentID: Credits]]()
            for owner in contribution.owners {
                // For self-referential owners, set payout to 0 to avoid circular credit
                let actualEarning = (owner.ownerId == contribution.spenderId) ? 0 : owner.earning
                payouts[owner.ownerId ?? owner.threadId] = owner.influence.mapValues { influence in actualEarning * influence }
            }
            self.payouts = payouts
            // totalCost is the gross cost: llmCost + serviceCharge, regardless of self-referential
            // zeroing. This matches contribution.totalCost so callers can compare across both types.
            self.totalCost = contribution.totalCost
            self.netCost = payouts.values.reduce(0) { $0 + $1.values.reduce(0, +) } + contribution.serviceCharge
            self.selfReferentialSavings = contribution.totalCost - self.netCost
        }

        enum CodingKeys: String, CodingKey {
            case id
            case timestamp
            case documentIds              = "document_ids"
            case totalCost                = "total_cost"
            case serviceCharge            = "service_charge"
            case payouts
            case netCost                  = "net_cost"
            case selfReferentialSavings   = "self_referential_savings"
            case threadIds                 = "thread_ids"
        }
    }
}