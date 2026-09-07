//
//  Wallet.swift
//  sewn-server
//
//  Created by Ritesh Pakala on 4/19/26.
//

import Foundation
import Hummingbird

// MARK: - Response

struct WalletResponse: Codable {
    /// Cumulative credits earned across all of the owner's groups.
    let totalEarnings: Gita.Credits
    /// Current spendable balance.
    let balance: Gita.Credits
    /// Total credits spent on inference across all exchanges.
    let totalSpent: Gita.Credits
    /// Credits the owner has already cashed out (sum of all wallet transactions).
    let totalCashedOut: Gita.Credits
    /// Groups with per-group earnings populated.
    let groups: [Sewn.Group]
    /// Inference credit exchange history.
    let exchanges: [Gita.CreditExchange]
    /// Cashout transaction history.
    let transactions: [Gita.Transaction]

    enum CodingKeys: String, CodingKey {
        case totalEarnings  = "total_earnings"
        case balance
        case totalSpent     = "total_spent"
        case totalCashedOut = "total_cashed_out"
        case groups
        case exchanges
        case transactions
    }
}

// MARK: - Route

/// Registers GET /v1/wallet — returns the authenticated user's wallet summary:
/// cumulative earnings (aggregated live from groups), cashout history from the
/// WalletRegistry, and the full group list so the client can break down earnings
/// per group.
func registerWalletRoute(_ router: some RouterMethods<SewnRequestContext>, _ sewn: Sewn) {
    router.get("/v1/wallet") { request, context async throws -> WalletResponse in
        guard let ownerId = context.authUserId else {
            throw HTTPError(.unauthorized, message: "Missing authenticated user ID")
        }

        let normalizedId = ownerId.lowercased()

        let (rawGroups, _, _) = await sewn.fanoutLibrary(ownerId: normalizedId)
        let docStats = sewn.registry?.documentStats ?? [:]
        let groups: [Sewn.Group] = rawGroups.map { group in
            var g = group
            g.totalEarnings = group.documents
                .reduce(0.0) { $0 + (docStats[$1.id]?.totalEarned ?? 0) }
            return g
        }

        let totalEarnings = groups.reduce(0.0) { $0 + ($1.totalEarnings ?? 0) }

        let wallet         = await sewn.gitaWallet(for: normalizedId)

        return WalletResponse(
            totalEarnings:  totalEarnings,
            balance:        wallet.balance,
            totalSpent:     wallet.totalSpent,
            totalCashedOut: wallet.totalCashedOut,
            groups:         groups,
            exchanges:      wallet.exchanges,
            transactions:   wallet.transactions
        )
    }
}
