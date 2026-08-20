//
//  Gita+Wallet.swift
//  seer-server
//
//  Created by Ritesh Pakala on 4/19/26.
//

import Foundation

extension Gita {
    /// A single owner's wallet: their current balance, inference exchanges, and cashout history.
    struct Wallet: Codable, Sendable {
        static let initialBalance: Credits = 1_000_000

        let ownerId: OwnerID
        var balance: Credits
        var exchanges: [CreditExchange]
        var transactions: [Transaction]

        init(ownerId: OwnerID) {
            self.ownerId = ownerId
            self.balance = Self.initialBalance
            self.exchanges = []
            self.transactions = []
        }

        var totalSpent: Credits      { exchanges.reduce(0)    { $0 + $1.netCost } }
        var totalCashedOut: Credits  { transactions.reduce(0) { $0 + $1.amount    } }

        mutating func record(_ exchange: CreditExchange) {
            exchanges.append(exchange)
            balance -= exchange.netCost
        }

        mutating func record(_ transaction: Transaction) {
            transactions.append(transaction)
        }

        mutating func addBalance(_ amount: Credits) {
            balance += amount
        }

        enum CodingKeys: String, CodingKey {
            case ownerId      = "owner_id"
            case balance
            case exchanges
            case transactions
        }
    }
    
    /// Creates a wallet entry for `ownerId` at `initialBalance` if one does not already exist.
    /// Call this at sign-up so the balance is stamped at account-creation time.
    func initializeWallet(for ownerId: OwnerID) {
        guard walletRegistry.wallets[ownerId] == nil else { return }
        walletRegistry.wallets[ownerId] = Wallet(ownerId: ownerId)
        walletPersistence.save(state: walletRegistry)
    }

    func recordExchange(_ exchange: CreditExchange, spenderId: OwnerID) {
        walletRegistry.record(exchange, spenderId: spenderId)
        walletPersistence.save(state: walletRegistry)
    }

    func recordCashout(ownerId: OwnerID, amount: Credits) {
        let tx = Transaction(ownerId: ownerId, amount: amount)
        walletRegistry.record(tx)
        walletPersistence.save(state: walletRegistry)
        logger.info("Wallet", "Cashout recorded for \(ownerId): \(CreditConversion.formattedCredits(amount))", service: .gita)
    }
}
