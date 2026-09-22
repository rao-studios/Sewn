//
//  Flow2_GitaWalletTests.swift
//  sewn-serverTests
//
//  Tests for the Gita wallet system:
//   - Gita.Wallet            — balance, exchange recording, cashout recording
//   - Gita.WalletRegistry    — on-demand wallet creation, per-owner keying
//   - Gita.CreditExchange    — document IDs and payouts captured from contribution
//   - Gita.initializeWallet  — idempotent sign-up initialization
//   - spenderId flow         — priceContribution stamps spenderId from request
//

import XCTest
@testable import sewn_server

final class Flow2_GitaWalletTests: XCTestCase {

    private var gita: Gita!

    override func setUp() {
        super.setUp()
        gita = Gita(logger: .test)
    }

    // MARK: - Helpers

    private func makePartition(documentId: String, ownerId: String, text: String) -> Sewn.Partition {
        Sewn.Partition.test(documentId: documentId, text: text, ownerId: ownerId)
    }

    private func pricedContribution(spenderId: String? = "alice") -> Gita.Contribution {
        let partitions = [
            makePartition(documentId: "docA", ownerId: "bob",   text: "one two three four"),
            makePartition(documentId: "docB", ownerId: "carol", text: "five six"),
        ]
        let contribution = gita.royalty(for: partitions)
        let ledger       = Gita.TokenLedger.test()
        let request      = spenderId.map { SewnRequest(ownerId: $0, group: nil, aggregate: nil, scope: nil, requestID: nil, callerApp: nil) }
        return gita.priceContribution(
            contribution,
            ledger: ledger,
            strategy: .init(pricing: .scaled(baseRate: 0.20, surge: nil)),
            request: request
        )
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: 1 — Wallet initial state
    // ─────────────────────────────────────────────────────────────────────────

    func testNewWalletStartsAtInitialBalance() {
        let wallet = Gita.Wallet(ownerId: "alice")
        XCTAssertEqual(wallet.balance, Gita.Wallet.initialBalance)
    }

    func testNewWalletHasNoExchanges() {
        let wallet = Gita.Wallet(ownerId: "alice")
        XCTAssertTrue(wallet.exchanges.isEmpty)
        XCTAssertEqual(wallet.totalSpent, 0)
    }

    func testNewWalletHasNoTransactions() {
        let wallet = Gita.Wallet(ownerId: "alice")
        XCTAssertTrue(wallet.transactions.isEmpty)
        XCTAssertEqual(wallet.totalCashedOut, 0)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: 2 — Exchange recording
    // ─────────────────────────────────────────────────────────────────────────

    func testRecordExchangeDeductsBalance() {
        var wallet   = Gita.Wallet(ownerId: "alice")
        let priced   = pricedContribution()
        let exchange = Gita.CreditExchange(contribution: priced)

        wallet.record(exchange)

        XCTAssertEqual(wallet.balance, Gita.Wallet.initialBalance - exchange.netCost, accuracy: 1e-9)
    }

    func testRecordExchangeAppended() {
        var wallet   = Gita.Wallet(ownerId: "alice")
        let exchange = Gita.CreditExchange(contribution: pricedContribution())

        wallet.record(exchange)

        XCTAssertEqual(wallet.exchanges.count, 1)
    }

    func testTotalSpentSumsAllExchanges() {
        var wallet = Gita.Wallet(ownerId: "alice")
        let e1     = Gita.CreditExchange(contribution: pricedContribution())
        let e2     = Gita.CreditExchange(contribution: pricedContribution())

        wallet.record(e1)
        wallet.record(e2)

        XCTAssertEqual(wallet.totalSpent, e1.netCost + e2.netCost, accuracy: 1e-9)
    }

    func testBalanceAfterMultipleExchanges() {
        var wallet = Gita.Wallet(ownerId: "alice")
        let e1     = Gita.CreditExchange(contribution: pricedContribution())
        let e2     = Gita.CreditExchange(contribution: pricedContribution())

        wallet.record(e1)
        wallet.record(e2)

        let expected = Gita.Wallet.initialBalance - e1.netCost - e2.netCost
        XCTAssertEqual(wallet.balance, expected, accuracy: 1e-9)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: 3 — Cashout recording
    // ─────────────────────────────────────────────────────────────────────────

    func testRecordTransactionAppended() {
        var wallet = Gita.Wallet(ownerId: "alice")
        let tx     = Gita.Transaction(ownerId: "alice", amount: 500)

        wallet.record(tx)

        XCTAssertEqual(wallet.transactions.count, 1)
    }

    func testTotalCashedOutSumsTransactions() {
        var wallet = Gita.Wallet(ownerId: "alice")
        wallet.record(Gita.Transaction(ownerId: "alice", amount: 200))
        wallet.record(Gita.Transaction(ownerId: "alice", amount: 350))

        XCTAssertEqual(wallet.totalCashedOut, 550, accuracy: 1e-9)
    }

    func testRecordTransactionDoesNotChangeBalance() {
        var wallet = Gita.Wallet(ownerId: "alice")
        let before = wallet.balance
        wallet.record(Gita.Transaction(ownerId: "alice", amount: 1000))

        XCTAssertEqual(wallet.balance, before)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: 4 — addBalance
    // ─────────────────────────────────────────────────────────────────────────

    func testAddBalanceIncreasesBalance() {
        var wallet = Gita.Wallet(ownerId: "alice")
        wallet.addBalance(5_000)
        XCTAssertEqual(wallet.balance, Gita.Wallet.initialBalance + 5_000, accuracy: 1e-9)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: 5 — WalletRegistry
    // ─────────────────────────────────────────────────────────────────────────

    func testRegistryReturnsDefaultWalletForUnknownOwner() {
        let registry = Gita.WalletRegistry()
        let wallet   = registry.wallet(for: "unknown")
        XCTAssertEqual(wallet.balance, Gita.Wallet.initialBalance)
        XCTAssertTrue(wallet.exchanges.isEmpty)
    }

    func testRegistryRecordExchangeCreatesWalletOnDemand() {
        var registry = Gita.WalletRegistry()
        let exchange = Gita.CreditExchange(contribution: pricedContribution())

        registry.record(exchange, spenderId: "alice")

        XCTAssertNotNil(registry.wallets["alice"])
        XCTAssertEqual(registry.wallets["alice"]?.exchanges.count, 1)
    }

    func testRegistryRecordTransactionCreatesWalletOnDemand() {
        var registry = Gita.WalletRegistry()
        let tx       = Gita.Transaction(ownerId: "alice", amount: 100)

        registry.record(tx)

        XCTAssertNotNil(registry.wallets["alice"])
        XCTAssertEqual(registry.wallets["alice"]?.transactions.count, 1)
    }

    func testRegistryIsolatesWalletsPerOwner() {
        var registry = Gita.WalletRegistry()
        let e1       = Gita.CreditExchange(contribution: pricedContribution())
        let e2       = Gita.CreditExchange(contribution: pricedContribution())

        registry.record(e1, spenderId: "alice")
        registry.record(e2, spenderId: "bob")

        XCTAssertEqual(registry.wallets["alice"]?.exchanges.count, 1)
        XCTAssertEqual(registry.wallets["bob"]?.exchanges.count,   1)
    }

    func testRegistryAddBalance() {
        var registry = Gita.WalletRegistry()
        registry.addBalance(2_000, for: "alice")
        XCTAssertEqual(registry.wallet(for: "alice").balance, Gita.Wallet.initialBalance + 2_000, accuracy: 1e-9)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: 6 — initializeWallet
    // ─────────────────────────────────────────────────────────────────────────

    func testInitializeWalletCreatesEntry() {
        gita.initializeWallet(for: "alice")
        XCTAssertNotNil(gita.walletRegistry.wallets["alice"])
    }

    func testInitializeWalletSetsInitialBalance() {
        gita.initializeWallet(for: "alice")
        XCTAssertEqual(gita.walletRegistry.wallets["alice"]?.balance, Gita.Wallet.initialBalance)
    }

    func testInitializeWalletIsIdempotent() {
        gita.initializeWallet(for: "alice")
        // Simulate spending some credits then call initializeWallet again.
        let exchange = Gita.CreditExchange(contribution: pricedContribution())
        gita.walletRegistry.wallets["alice"]?.record(exchange)
        let balanceAfterSpend = gita.walletRegistry.wallets["alice"]!.balance

        gita.initializeWallet(for: "alice")

        XCTAssertEqual(gita.walletRegistry.wallets["alice"]?.balance, balanceAfterSpend,
            "initializeWallet must not reset an existing wallet")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: 7 — CreditExchange captures correct data
    // ─────────────────────────────────────────────────────────────────────────

    func testCreditExchangeCapturesDocumentIds() {
        let priced   = pricedContribution()
        let exchange = Gita.CreditExchange(contribution: priced)

        XCTAssertTrue(exchange.documentIds.contains("docA"))
        XCTAssertTrue(exchange.documentIds.contains("docB"))
    }

    func testCreditExchangeTotalCostMatchesContribution() {
        let priced   = pricedContribution()
        let exchange = Gita.CreditExchange(contribution: priced)

        XCTAssertEqual(exchange.totalCost,     priced.totalCost,     accuracy: 1e-9)
        XCTAssertEqual(exchange.serviceCharge, priced.serviceCharge, accuracy: 1e-9)
    }

    func testCreditExchangePayoutsMatchOwnerEarnings() {
        let priced   = pricedContribution()
        let exchange = Gita.CreditExchange(contribution: priced)

        for owner in priced.owners where owner.earning > 0 {
            let ownerKey = owner.ownerId ?? owner.threadId
            let docPayouts = exchange.payouts[ownerKey]
            XCTAssertNotNil(docPayouts, "\(ownerKey) must have a payout entry")
            for (_, credit) in docPayouts ?? [:] {
                XCTAssertEqual(credit, owner.earning, accuracy: 1e-9,
                    "\(ownerKey) per-document credit must equal owner.earning")
            }
        }
    }

    func testCreditExchangeHasUniqueId() {
        let e1 = Gita.CreditExchange(contribution: pricedContribution())
        let e2 = Gita.CreditExchange(contribution: pricedContribution())
        XCTAssertNotEqual(e1.id, e2.id)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: 8 — spenderId flows through priceContribution
    // ─────────────────────────────────────────────────────────────────────────

    func testPriceContributionStampsSpenderId() {
        let priced = pricedContribution(spenderId: "alice")
        XCTAssertEqual(priced.spenderId, "alice")
    }

    func testPriceContributionNilSpenderIdWhenNoRequest() {
        let priced = pricedContribution(spenderId: nil)
        XCTAssertNil(priced.spenderId)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: 9 — Self-referential inference (spender owns contributing documents)
    // ─────────────────────────────────────────────────────────────────────────

    func testSelfReferentialOwnerEarnsZero() {
        // bob is both the spender and an owner of a contributing document.
        let partitions = [
            makePartition(documentId: "docA", ownerId: "bob",   text: "one two three four"),
            makePartition(documentId: "docB", ownerId: "carol", text: "five six"),
        ]
        let contribution = gita.royalty(for: partitions)
        let ledger       = Gita.TokenLedger.test()
        let request      = SewnRequest(ownerId: "bob", group: nil, aggregate: nil, scope: nil, requestID: nil, callerApp: nil)
        let priced       = gita.priceContribution(contribution, ledger: ledger, request: request)

        let bob = priced.owners.first(where: { $0.ownerId == "bob" })!
        let carol = priced.owners.first(where: { $0.ownerId == "carol" })!
        XCTAssertGreaterThan(bob.earning, 0, 
            "spender's own documents now show their full earning in contribution for auditing")
        XCTAssertEqual(priced.totalPayout, bob.earning + carol.earning, accuracy: 1e-9,
            "totalPayout must equal sum of all owner earnings (including self-referential)")
    }

    func testSelfReferentialOtherOwnersStillEarn() {
        let partitions = [
            makePartition(documentId: "docA", ownerId: "bob",   text: "one two three four"),
            makePartition(documentId: "docB", ownerId: "carol", text: "five six"),
        ]
        let contribution = gita.royalty(for: partitions)
        let ledger       = Gita.TokenLedger.test()
        let request      = SewnRequest(ownerId: "bob", group: nil, aggregate: nil, scope: nil, requestID: nil, callerApp: nil)
        let priced       = gita.priceContribution(contribution, ledger: ledger, request: request)

        let carol = priced.owners.first(where: { $0.ownerId == "carol" })!
        XCTAssertGreaterThan(carol.earning, 0,
            "non-spender owners must still earn their royalty share")
    }

    func testSelfReferentialOwnerStillRecordedInExchange() {
        let partitions = [
            makePartition(documentId: "docA", ownerId: "bob",   text: "one two three four"),
            makePartition(documentId: "docB", ownerId: "carol", text: "five six"),
        ]
        let contribution = gita.royalty(for: partitions)
        let ledger       = Gita.TokenLedger.test()
        let request      = SewnRequest(ownerId: "bob", group: nil, aggregate: nil, scope: nil, requestID: nil, callerApp: nil)
        let priced       = gita.priceContribution(contribution, ledger: ledger, request: request)
        let exchange     = Gita.CreditExchange(contribution: priced)

        XCTAssertNotNil(exchange.payouts["bob"],
            "self-referential owner must still appear in exchange payouts")
        let bobDocCredits = Array(exchange.payouts["bob"]?.values ?? [:].values)
        XCTAssertTrue(bobDocCredits.allSatisfy { $0 == 0 },
            "self-referential owner's per-document credits must all be $0")
    }

    func testSelfReferentialTotalPayoutExcludesSelfEarning() {
        let partitions = [
            makePartition(documentId: "docA", ownerId: "bob",   text: "one two three four"),
            makePartition(documentId: "docB", ownerId: "carol", text: "five six"),
        ]
        let contribution = gita.royalty(for: partitions)
        let ledger       = Gita.TokenLedger.test()
        let request      = SewnRequest(ownerId: "bob", group: nil, aggregate: nil, scope: nil, requestID: nil, callerApp: nil)
        let priced       = gita.priceContribution(contribution, ledger: ledger, request: request)

        let carol       = priced.owners.first(where: { $0.ownerId == "carol" })!
        let bob = priced.owners.first(where: { $0.ownerId == "bob" })!
        XCTAssertEqual(priced.totalPayout, bob.earning + carol.earning, accuracy: 1e-9,
            "totalPayout must equal sum of all owner earnings (including self-referential for auditing)")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: 10 — Net cost calculation for self-referential inference
    // ─────────────────────────────────────────────────────────────────────────

    func testNetCostEqualsTotalCostWhenNoSelfReferential() {
        let partitions = [
            makePartition(documentId: "docA", ownerId: "bob",   text: "one two three four"),
            makePartition(documentId: "docB", ownerId: "carol", text: "five six"),
        ]
        let contribution = gita.royalty(for: partitions)
        let ledger       = Gita.TokenLedger.test()
        let request      = SewnRequest(ownerId: "alice", group: nil, aggregate: nil, scope: nil, requestID: nil, callerApp: nil)
        let priced       = gita.priceContribution(contribution, ledger: ledger, request: request)
        let exchange     = Gita.CreditExchange(contribution: priced)

        XCTAssertEqual(exchange.netCost, exchange.totalCost, accuracy: 1e-9,
            "netCost must equal totalCost when spender owns no documents")
        XCTAssertEqual(exchange.selfReferentialSavings, 0, accuracy: 1e-9,
            "selfReferentialSavings must be zero when spender owns no documents")
    }

    func testNetCostExcludesSelfEarningWhenSelfReferential() {
        let partitions = [
            makePartition(documentId: "docA", ownerId: "bob",   text: "one two three four"),
            makePartition(documentId: "docB", ownerId: "carol", text: "five six"),
        ]
        let contribution = gita.royalty(for: partitions)
        let ledger       = Gita.TokenLedger.test()
        let request      = SewnRequest(ownerId: "bob", group: nil, aggregate: nil, scope: nil, requestID: nil, callerApp: nil)
        let priced       = gita.priceContribution(contribution, ledger: ledger, request: request)
        let exchange     = Gita.CreditExchange(contribution: priced)

        // netCost = serviceCharge + sum of actual payouts (which excludes bob's earning)
        let actualPayoutSum = exchange.payouts.values.reduce(0) { $0 + $1.values.reduce(0, +) }
        let expectedNetCost = priced.serviceCharge + actualPayoutSum
        XCTAssertEqual(exchange.netCost, expectedNetCost, accuracy: 1e-9,
            "netCost must equal serviceCharge + sum of actual payouts when spender owns some documents")
        XCTAssertLessThan(exchange.netCost, exchange.totalCost,
            "netCost must be less than totalCost when spender owns some documents")
        XCTAssertGreaterThan(exchange.selfReferentialSavings, 0,
            "selfReferentialSavings must be positive when spender owns some documents")
    }

    func testSelfReferentialSavingsInvariant() {
        // netCost + selfReferentialSavings must always equal totalCost.
        let partitions = [
            makePartition(documentId: "docA", ownerId: "bob",   text: "one two three four"),
            makePartition(documentId: "docB", ownerId: "carol", text: "five six"),
        ]
        let contribution = gita.royalty(for: partitions)
        let ledger       = Gita.TokenLedger.test()
        let request      = SewnRequest(ownerId: "bob", group: nil, aggregate: nil, scope: nil, requestID: nil, callerApp: nil)
        let priced       = gita.priceContribution(contribution, ledger: ledger, request: request)
        let exchange     = Gita.CreditExchange(contribution: priced)

        XCTAssertEqual(exchange.netCost + exchange.selfReferentialSavings, exchange.totalCost, accuracy: 1e-9,
            "netCost + selfReferentialSavings must equal totalCost")
    }

    func testAllDocumentsSelfReferentialOnlyPaysServiceCharge() {
        // Spender owns ALL retrieved documents — net cost is just the service fee.
        let partitions = [
            makePartition(documentId: "docA", ownerId: "bob", text: "one two three four"),
            makePartition(documentId: "docB", ownerId: "bob", text: "five six seven eight"),
        ]
        let contribution = gita.royalty(for: partitions)
        let ledger       = Gita.TokenLedger.test()
        let strategy     = Gita.ServiceChargeStrategy.flat(5.0)
        let request      = SewnRequest(ownerId: "bob", group: nil, aggregate: nil, scope: nil, requestID: nil, callerApp: nil)
        let priced       = gita.priceContribution(contribution, ledger: ledger, strategy: strategy, request: request)
        let exchange     = Gita.CreditExchange(contribution: priced)

        XCTAssertEqual(exchange.netCost, exchange.serviceCharge, accuracy: 1e-9,
            "when all documents are self-referential, netCost must equal only the service charge")
        XCTAssertEqual(exchange.selfReferentialSavings, priced.totalPayout, accuracy: 1e-9,
            "selfReferentialSavings must equal the entire LLM cost when all docs are self-referential")
        XCTAssertEqual(exchange.netCost + exchange.selfReferentialSavings, exchange.totalCost, accuracy: 1e-9,
            "invariant must hold in the all-self-referential case")
    }

    func testWalletDeductsNetCostNotTotalCost() {
        var wallet = Gita.Wallet(ownerId: "bob")
        let partitions = [
            makePartition(documentId: "docA", ownerId: "bob",   text: "one two three four"),
            makePartition(documentId: "docB", ownerId: "carol", text: "five six"),
        ]
        let contribution = gita.royalty(for: partitions)
        let ledger       = Gita.TokenLedger.test()
        let request      = SewnRequest(ownerId: "bob", group: nil, aggregate: nil, scope: nil, requestID: nil, callerApp: nil)
        let priced       = gita.priceContribution(contribution, ledger: ledger, request: request)
        let exchange     = Gita.CreditExchange(contribution: priced)

        wallet.record(exchange)

        let expectedBalance = Gita.Wallet.initialBalance - exchange.netCost
        XCTAssertEqual(wallet.balance, expectedBalance, accuracy: 1e-9,
            "wallet balance must be reduced by netCost, not totalCost")
    }
}
