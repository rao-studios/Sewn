//
//  Gita.WalletRegistry.swift
//  seer-server
//
//  Created by Ritesh Pakala on 4/19/26.
//

import Foundation

// MARK: - Transaction

extension Gita {
    /// Transaction record for a single owner cashout event.
    struct Transaction: Codable, Sendable {
        let id: String
        let ownerId: OwnerID
        let amount: Credits
        let date: Date

        init(ownerId: OwnerID, amount: Credits, date: Date = Date()) {
            self.id = UUID().uuidString
            self.ownerId = ownerId
            self.amount = amount
            self.date = date
        }

        enum CodingKeys: String, CodingKey {
            case id
            case ownerId = "owner_id"
            case amount
            case date
        }
    }
}

// MARK: - WalletRegistry

extension Gita {
    /// Persisted wallet registry keyed by owner ID.
    struct WalletRegistry: Codable, Sendable {
        var wallets: [OwnerID: Wallet] = [:]

        func wallet(for ownerId: OwnerID) -> Wallet {
            wallets[ownerId] ?? Wallet(ownerId: ownerId)
        }

        mutating func record(_ exchange: CreditExchange, spenderId: OwnerID) {
            wallets[spenderId, default: Wallet(ownerId: spenderId)].record(exchange)
        }

        mutating func record(_ transaction: Transaction) {
            wallets[transaction.ownerId, default: Wallet(ownerId: transaction.ownerId)].record(transaction)
        }

        mutating func addBalance(_ amount: Credits, for ownerId: OwnerID) {
            wallets[ownerId, default: Wallet(ownerId: ownerId)].addBalance(amount)
        }

        enum CodingKeys: String, CodingKey {
            case wallets
        }
    }
}
