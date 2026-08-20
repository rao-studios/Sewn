//
//  Flow2_GitaCreditTests.swift
//  seer-serverTests
//
//  Tests for the Gita credit system introduced in:
//   - Gita.TokenCost.swift   — Credits, CreditConversion, ModelPricing, ModelCatalog,
//                              TokenLedger, ServiceChargeStrategy
//   - Gita+Royalty.swift     — priceContribution, documentEarnings
//
//  Coverage areas:
//   1. CreditConversion  — unit arithmetic and formatting
//   2. ModelPricing      — cost calculation from token counts
//   3. ModelCatalog      — known-model lookup and unknown-model fallback
//   4. TokenLedger       — accumulation, totals, isEmpty
//   5. ServiceChargeStrategy (fixed)  — charge is always constant
//   6. ServiceChargeStrategy (scaled) — base rate, surge interpolation, bounds
//   7. priceContribution — invariant, earnings, ledger attachment
//   8. documentEarnings  — per-document distribution via owner influence
//

import XCTest
@testable import seer_server

final class Flow2_GitaCreditTests: XCTestCase {

    private var gita: Gita!

    override func setUp() {
        super.setUp()
        gita = Gita(logger: .test)
    }

    // MARK: - Helpers

    private func makePartition(
        id: String = UUID().uuidString,
        documentId: String,
        ownerId: String,
        text: String
    ) -> Seer.Partition {
        Seer.Partition.test(id: id, documentId: documentId, text: text, ownerId: ownerId)
    }

    /// Returns a contribution with two owners (alice 4/6, bob 2/6) — no cost attached.
    private func twoOwnerContribution() -> Gita.Contribution {
        let partitions = [
            makePartition(documentId: "docA", ownerId: "alice", text: "one two three four"),
            makePartition(documentId: "docB", ownerId: "bob",   text: "five six"),
        ]
        return gita.royalty(for: partitions)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: 1 — CreditConversion
    // ─────────────────────────────────────────────────────────────────────────

    func testCreditConversionBaseline() {
        // $0.10 == 10 credits
        XCTAssertEqual(Gita.CreditConversion.fromDollars(0.10), 10.0, accuracy: 1e-9)
    }

    func testCreditConversionOneDollar() {
        XCTAssertEqual(Gita.CreditConversion.fromDollars(1.00), 100.0, accuracy: 1e-9)
    }

    func testCreditConversionToDollars() {
        XCTAssertEqual(Gita.CreditConversion.toDollars(100.0), 1.00, accuracy: 1e-9)
    }

    func testCreditConversionRoundTrip() {
        let original = 37.5
        let roundTripped = Gita.CreditConversion.fromDollars(
            Gita.CreditConversion.toDollars(original)
        )
        XCTAssertEqual(roundTripped, original, accuracy: 1e-9,
            "fromDollars(toDollars(x)) must return x")
    }

    func testCreditConversionFormattedCredits() {
        let formatted = Gita.CreditConversion.formattedCredits(1.23456)
        XCTAssertEqual(formatted, "1.2346cr",
            "formattedCredits must show 4 decimal places with 'cr' suffix")
    }

    func testCreditConversionFormattedDollars() {
        let formatted = Gita.CreditConversion.formattedDollars(100.0)
        XCTAssertEqual(formatted, "$1.000000",
            "formattedDollars must show 6 decimal places with '$' prefix")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: 2 — ModelPricing
    // ─────────────────────────────────────────────────────────────────────────

    func testModelPricingZeroTokensIsZeroCost() {
        let pricing = Gita.ModelPricing(promptCreditsPerToken: 0.0003, completionCreditsPerToken: 0.0009)
        XCTAssertEqual(pricing.cost(promptTokens: 0, completionTokens: 0), 0.0)
    }

    func testModelPricingOnlyPromptTokens() {
        let pricing = Gita.ModelPricing(promptCreditsPerToken: 0.0003, completionCreditsPerToken: 0.0009)
        let cost = pricing.cost(promptTokens: 1000, completionTokens: 0)
        XCTAssertEqual(cost, 0.3, accuracy: 1e-9)
    }

    func testModelPricingOnlyCompletionTokens() {
        let pricing = Gita.ModelPricing(promptCreditsPerToken: 0.0003, completionCreditsPerToken: 0.0009)
        let cost = pricing.cost(promptTokens: 0, completionTokens: 1000)
        XCTAssertEqual(cost, 0.9, accuracy: 1e-9)
    }

    func testModelPricingBothTokenTypes() {
        // 1200 prompt × 0.0003 + 340 completion × 0.0009 = 0.360 + 0.306 = 0.666
        let pricing = Gita.ModelPricing(promptCreditsPerToken: 0.0003, completionCreditsPerToken: 0.0009)
        let cost = pricing.cost(promptTokens: 1200, completionTokens: 340)
        XCTAssertEqual(cost, 0.666, accuracy: 1e-6)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: 3 — ModelCatalog
    // ─────────────────────────────────────────────────────────────────────────

    func testModelCatalogKnownModelsMediumSmallTiny() {
        for model in ["mistral-medium", "mistral-small", "mistral-tiny"] {
            let pricing = Gita.ModelCatalog.pricing(for: model)
            XCTAssertGreaterThan(pricing.promptCreditsPerToken,     0, "\(model): prompt rate must be > 0")
            XCTAssertGreaterThan(pricing.completionCreditsPerToken, 0, "\(model): completion rate must be > 0")
        }
    }

    func testModelCatalogMediumMoreExpensiveThanTiny() {
        let medium = Gita.ModelCatalog.pricing(for: "mistral-medium")
        let tiny   = Gita.ModelCatalog.pricing(for: "mistral-tiny")
        XCTAssertGreaterThan(medium.promptCreditsPerToken,     tiny.promptCreditsPerToken,
            "mistral-medium prompt rate must exceed mistral-tiny")
        XCTAssertGreaterThan(medium.completionCreditsPerToken, tiny.completionCreditsPerToken,
            "mistral-medium completion rate must exceed mistral-tiny")
    }

    func testModelCatalogUnknownModelFallsBackToMedium() {
        let fallback = Gita.ModelCatalog.pricing(for: "nonexistent-model-xyz")
        let medium   = Gita.ModelCatalog.pricing(for: "mistral-medium")
        XCTAssertEqual(fallback.promptCreditsPerToken,     medium.promptCreditsPerToken,
            "unknown model must fall back to mistral-medium prompt rate")
        XCTAssertEqual(fallback.completionCreditsPerToken, medium.completionCreditsPerToken,
            "unknown model must fall back to mistral-medium completion rate")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: 4 — TokenLedger
    // ─────────────────────────────────────────────────────────────────────────

    func testEmptyLedgerIsEmpty() {
        let ledger = Gita.TokenLedger()
        XCTAssertTrue(ledger.isEmpty)
        XCTAssertEqual(ledger.totalTokens,  0)
        XCTAssertEqual(ledger.totalCredits, 0.0)
    }

    func testLedgerIsNotEmptyAfterRecord() {
        var ledger = Gita.TokenLedger()
        ledger.record(model: "mistral-medium", promptTokens: 10, completionTokens: 5)
        XCTAssertFalse(ledger.isEmpty)
    }

    func testLedgerSingleCallTokenTotals() {
        var ledger = Gita.TokenLedger()
        ledger.record(model: "mistral-medium", promptTokens: 100, completionTokens: 50)
        XCTAssertEqual(ledger.totalPromptTokens,     100)
        XCTAssertEqual(ledger.totalCompletionTokens, 50)
        XCTAssertEqual(ledger.totalTokens,           150)
    }

    func testLedgerMultipleCallsAccumulate() {
        var ledger = Gita.TokenLedger()
        ledger.record(model: "mistral-medium", promptTokens: 1200, completionTokens: 340)
        ledger.record(model: "mistral-tiny",   promptTokens: 80,   completionTokens: 20)
        XCTAssertEqual(ledger.lines.count,           2)
        XCTAssertEqual(ledger.totalPromptTokens,     1280)
        XCTAssertEqual(ledger.totalCompletionTokens, 360)
        XCTAssertEqual(ledger.totalTokens,           1640)
    }

    func testLedgerTotalCreditsMatchesSumOfLines() {
        var ledger = Gita.TokenLedger()
        ledger.record(model: "mistral-medium", promptTokens: 1200, completionTokens: 340)
        ledger.record(model: "mistral-tiny",   promptTokens: 80,   completionTokens: 20)
        let lineSum = ledger.lines.reduce(0.0) { $0 + $1.credits }
        XCTAssertEqual(ledger.totalCredits, lineSum, accuracy: 1e-12,
            "totalCredits must equal the sum of all line credits")
    }

    func testLedgerCreditsAreComputedFromCatalog() {
        // mistral-medium: 100 prompt × rate + 50 completion × rate
        var ledger = Gita.TokenLedger()
        ledger.record(model: "mistral-medium", promptTokens: 100, completionTokens: 50)
        let expected = Gita.ModelCatalog.pricing(for: "mistral-medium")
            .cost(promptTokens: 100, completionTokens: 50)
        XCTAssertEqual(ledger.totalCredits, expected, accuracy: 1e-12)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: 5 — ServiceChargeStrategy: Fixed
    // ─────────────────────────────────────────────────────────────────────────

    func testFixedStrategyReturnsFlatAmount() {
        let strategy = Gita.ServiceChargeStrategy.flat(5.0)
        XCTAssertEqual(strategy.charge(llmCost: 10.0, currentLoad: 1), 5.0)
        XCTAssertEqual(strategy.charge(llmCost: 10.0, currentLoad: 5), 5.0,
            "fixed strategy must ignore currentLoad")
        XCTAssertEqual(strategy.charge(llmCost: 100.0, currentLoad: 1), 5.0,
            "fixed strategy must ignore llmCost")
    }

    func testFixedStrategySurgeMultiplierIsAlwaysOne() {
        let strategy = Gita.ServiceChargeStrategy.flat(3.0)
        XCTAssertEqual(strategy.surgeMultiplier(currentLoad: 1),  1.0)
        XCTAssertEqual(strategy.surgeMultiplier(currentLoad: 10), 1.0,
            "fixed strategy surge multiplier must always be 1.0")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: 6 — ServiceChargeStrategy: Scaled + Surge
    // ─────────────────────────────────────────────────────────────────────────

    func testScaledStrategyNoSurgeAtIdleLoad() {
        // With no surge params, multiplier is 1.0.
        let strategy = Gita.ServiceChargeStrategy(
            pricing: .scaled(baseRate: 0.20, surge: nil)
        )
        XCTAssertEqual(strategy.charge(llmCost: 1.0, currentLoad: 1), 0.20, accuracy: 1e-9)
        XCTAssertEqual(strategy.surgeMultiplier(currentLoad: 1), 1.0)
    }

    func testSurgeMultiplierAtZeroLoad() {
        let surge    = Gita.ServiceChargeStrategy.SurgeParameters(maxConcurrentLoad: 10, maxSurgeMultiplier: 2.5)
        let strategy = Gita.ServiceChargeStrategy(pricing: .scaled(baseRate: 0.20, surge: surge))
        // currentLoad = 0 → ratio = 0 → multiplier = 1.0 + 0 × 1.5 = 1.0
        XCTAssertEqual(strategy.surgeMultiplier(currentLoad: 0), 1.0, accuracy: 1e-9)
    }

    func testSurgeMultiplierAtPeakLoad() {
        let surge    = Gita.ServiceChargeStrategy.SurgeParameters(maxConcurrentLoad: 10, maxSurgeMultiplier: 2.5)
        let strategy = Gita.ServiceChargeStrategy(pricing: .scaled(baseRate: 0.20, surge: surge))
        // currentLoad = 10 → ratio = 1.0 → multiplier = 1.0 + 1.0 × 1.5 = 2.5
        XCTAssertEqual(strategy.surgeMultiplier(currentLoad: 10), 2.5, accuracy: 1e-9)
    }

    func testSurgeMultiplierClampedAbovePeak() {
        let surge    = Gita.ServiceChargeStrategy.SurgeParameters(maxConcurrentLoad: 10, maxSurgeMultiplier: 2.5)
        let strategy = Gita.ServiceChargeStrategy(pricing: .scaled(baseRate: 0.20, surge: surge))
        // currentLoad > maxConcurrentLoad must not exceed maxSurgeMultiplier
        XCTAssertEqual(strategy.surgeMultiplier(currentLoad: 999), 2.5, accuracy: 1e-9,
            "multiplier must not exceed maxSurgeMultiplier even when load is absurdly high")
    }

    func testSurgeMultiplierLinearInterpolation() {
        let surge    = Gita.ServiceChargeStrategy.SurgeParameters(maxConcurrentLoad: 10, maxSurgeMultiplier: 2.5)
        let strategy = Gita.ServiceChargeStrategy(pricing: .scaled(baseRate: 0.20, surge: surge))
        // currentLoad = 5 → ratio = 0.5 → multiplier = 1.0 + 0.5 × 1.5 = 1.75
        XCTAssertEqual(strategy.surgeMultiplier(currentLoad: 5), 1.75, accuracy: 1e-9)
    }

    func testDefaultStrategyChargeIsCorrect() {
        // Default: 20% baseRate, surge up to 2.5× at 10 concurrent.
        // At load=1: ratio=0.1, multiplier=1.0+0.1×1.5=1.15, charge=1.0×0.20×1.15=0.23
        let charge = Gita.ServiceChargeStrategy.default.charge(llmCost: 1.0, currentLoad: 1)
        let expectedMultiplier = 1.0 + (1.0 / 10.0) * (2.5 - 1.0)
        let expected = 1.0 * 0.20 * expectedMultiplier
        XCTAssertEqual(charge, expected, accuracy: 1e-9)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: 7 — priceContribution
    // ─────────────────────────────────────────────────────────────────────────

    func testPriceContributionEmptyLedgerReturnsUnchanged() {
        let contribution = twoOwnerContribution()
        let empty        = Gita.TokenLedger()
        let priced       = gita.priceContribution(contribution, ledger: empty)

        // Nothing should have changed
        XCTAssertEqual(priced.totalCost,     0)
        XCTAssertEqual(priced.serviceCharge, 0)
        XCTAssertEqual(priced.totalPayout,   0)
        XCTAssertNil(priced.ledger)
    }

    func testPriceContributionInvariantPayoutPlusChargeEqualsTotalCost() {
        let contribution = twoOwnerContribution()
        let ledger       = Gita.TokenLedger.test()
        let priced       = gita.priceContribution(contribution, ledger: ledger)

        XCTAssertEqual(priced.totalPayout + priced.serviceCharge, priced.totalCost, accuracy: 1e-9,
            "totalPayout + serviceCharge must exactly equal totalCost")
    }

    func testPriceContributionTotalPayoutEqualsLLMCost() {
        let contribution = twoOwnerContribution()
        let ledger       = Gita.TokenLedger.test()
        let priced       = gita.priceContribution(contribution, ledger: ledger,
                                                   strategy: .init(pricing: .scaled(baseRate: 0.20, surge: nil)))
        // Owner payouts are distributed from the LLM cost only
        XCTAssertEqual(priced.totalPayout, ledger.totalCredits, accuracy: 1e-9,
            "totalPayout must equal the total LLM cost in credits")
    }

    func testPriceContributionOwnerEarningsProportionalToRoyalty() {
        let contribution = twoOwnerContribution()
        let ledger       = Gita.TokenLedger.test()
        let llmCost      = ledger.totalCredits
        let priced       = gita.priceContribution(contribution, ledger: ledger,
                                                   strategy: .init(pricing: .scaled(baseRate: 0.20, surge: nil)))

        let alice = priced.owners.first(where: { $0.ownerId == "alice" })!
        let bob   = priced.owners.first(where: { $0.ownerId == "bob" })!

        XCTAssertEqual(alice.earning, llmCost * alice.royalty, accuracy: 1e-9,
            "alice earning must be llmCost × royalty")
        XCTAssertEqual(bob.earning,   llmCost * bob.royalty,   accuracy: 1e-9,
            "bob earning must be llmCost × royalty")
    }

    func testPriceContributionOwnerEarningsSumToTotalPayout() {
        let contribution = twoOwnerContribution()
        let ledger       = Gita.TokenLedger.test()
        let priced       = gita.priceContribution(contribution, ledger: ledger)

        let earningSum = priced.owners.reduce(0.0) { $0 + $1.earning }
        XCTAssertEqual(earningSum, priced.totalPayout, accuracy: 1e-9,
            "sum of owner earnings must equal totalPayout")
    }

    func testPriceContributionSingleOwnerReceivesFullLLMCost() {
        let partitions = [
            makePartition(documentId: "d1", ownerId: "solo", text: "one two three four five"),
        ]
        let contribution = gita.royalty(for: partitions)
        let ledger       = Gita.TokenLedger.test()
        let priced       = gita.priceContribution(contribution, ledger: ledger,
                                                   strategy: .init(pricing: .scaled(baseRate: 0.20, surge: nil)))
        let solo = priced.owners.first!
        XCTAssertEqual(solo.earning, ledger.totalCredits, accuracy: 1e-9,
            "single owner must earn the entire LLM cost")
    }

    func testPriceContributionServiceChargeAppliedOnTopOfLLMCost() {
        let contribution = twoOwnerContribution()
        var ledger       = Gita.TokenLedger()
        ledger.record(model: "mistral-medium", promptTokens: 1000, completionTokens: 0)
        // Fixed service charge of 2 credits — independent of LLM cost
        let strategy = Gita.ServiceChargeStrategy.flat(2.0)
        let priced   = gita.priceContribution(contribution, ledger: ledger, strategy: strategy)

        XCTAssertEqual(priced.serviceCharge, 2.0, accuracy: 1e-9)
        XCTAssertEqual(priced.totalCost, priced.totalPayout + 2.0, accuracy: 1e-9)
    }

    func testPriceContributionAttachesLedger() {
        let contribution = twoOwnerContribution()
        let ledger       = Gita.TokenLedger.twoCall
        let priced       = gita.priceContribution(contribution, ledger: ledger)

        XCTAssertNotNil(priced.ledger, "ledger must be attached to the priced contribution")
        XCTAssertEqual(priced.ledger?.lines.count, 2,
            "ledger must carry both call lines")
    }

    func testPriceContributionPreservesRoyaltyShares() {
        // Pricing must not change royalty values — only add earning on top.
        let contribution = twoOwnerContribution()
        let ledger       = Gita.TokenLedger.test()
        let priced       = gita.priceContribution(contribution, ledger: ledger)

        for pricedOwner in priced.owners {
            let original = contribution.owners.first(where: { $0.ownerId == pricedOwner.ownerId })!
            XCTAssertEqual(pricedOwner.royalty, original.royalty, accuracy: 1e-12,
                "priceContribution must not mutate royalty values")
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: 8 — documentEarnings
    // ─────────────────────────────────────────────────────────────────────────

    func testDocumentEarningsEmptyWhenContributionNotPriced() {
        let contribution = twoOwnerContribution() // earning = 0 for all owners
        let earnings     = gita.documentEarnings(from: contribution)
        // All owners have earning == 0, so nothing should appear
        XCTAssertTrue(
            earnings.values.allSatisfy { $0 == 0 },
            "documentEarnings must be zero when contribution has not been priced"
        )
    }

    func testDocumentEarningsSingleOwnerSingleDocReceivesFullEarning() {
        let partitions = [
            makePartition(documentId: "docAlone", ownerId: "solo", text: "a b c d"),
        ]
        let contribution = gita.royalty(for: partitions)
        let ledger       = Gita.TokenLedger.test()
        let priced       = gita.priceContribution(contribution, ledger: ledger,
                                                   strategy: .init(pricing: .scaled(baseRate: 0.20, surge: nil)))
        let earnings     = gita.documentEarnings(from: priced)

        XCTAssertEqual(earnings["docAlone"] ?? -1, ledger.totalCredits, accuracy: 1e-9,
            "sole document must receive the owner's entire earning")
    }

    func testDocumentEarningsSumToOwnerEarning() {
        // alice owns docA and docB equally
        let partitions = [
            makePartition(documentId: "docA", ownerId: "alice", text: "a b c"),
            makePartition(documentId: "docB", ownerId: "alice", text: "d e f"),
        ]
        let contribution = gita.royalty(for: partitions)
        let ledger       = Gita.TokenLedger.test()
        let priced       = gita.priceContribution(contribution, ledger: ledger,
                                                   strategy: .init(pricing: .scaled(baseRate: 0.20, surge: nil)))
        let alice    = priced.owners.first(where: { $0.ownerId == "alice" })!
        let earnings = gita.documentEarnings(from: priced)

        let docAEarning = earnings["docA"] ?? 0
        let docBEarning = earnings["docB"] ?? 0
        XCTAssertEqual(docAEarning + docBEarning, alice.earning, accuracy: 1e-9,
            "docA + docB earnings must equal alice's total earning")
    }

    func testDocumentEarningsDistributedByInfluence() {
        // alice: docA has 6 words, docB has 2 words → influence 0.75 / 0.25
        let partitions = [
            makePartition(documentId: "docA", ownerId: "alice", text: "one two three four five six"),
            makePartition(documentId: "docB", ownerId: "alice", text: "seven eight"),
        ]
        let contribution = gita.royalty(for: partitions)
        let ledger       = Gita.TokenLedger.test()
        let priced       = gita.priceContribution(contribution, ledger: ledger,
                                                   strategy: .init(pricing: .scaled(baseRate: 0.20, surge: nil)))
        let alice    = priced.owners.first(where: { $0.ownerId == "alice" })!
        let earnings = gita.documentEarnings(from: priced)

        let expectedA = alice.earning * (alice.influence["docA"] ?? 0)
        let expectedB = alice.earning * (alice.influence["docB"] ?? 0)
        XCTAssertEqual(earnings["docA"] ?? 0, expectedA, accuracy: 1e-9,
            "docA earning must be alice.earning × influence[docA]")
        XCTAssertEqual(earnings["docB"] ?? 0, expectedB, accuracy: 1e-9,
            "docB earning must be alice.earning × influence[docB]")
    }

    func testDocumentEarningsFromTwoOwnersTwoDocuments() {
        let contribution = twoOwnerContribution()
        let ledger       = Gita.TokenLedger.test()
        let priced       = gita.priceContribution(contribution, ledger: ledger,
                                                   strategy: .init(pricing: .scaled(baseRate: 0.20, surge: nil)))
        let earnings     = gita.documentEarnings(from: priced)

        // Both documents must have non-zero earnings
        XCTAssertGreaterThan(earnings["docA"] ?? 0, 0, "docA must have positive earnings")
        XCTAssertGreaterThan(earnings["docB"] ?? 0, 0, "docB must have positive earnings")
    }

    func testDocumentEarningsTotalMatchesTotalPayoutWhenNoSpender() {
        // No spenderId → no self-referential exclusion → earnings sum equals totalPayout.
        let contribution = twoOwnerContribution()
        let ledger       = Gita.TokenLedger.test()
        let priced       = gita.priceContribution(contribution, ledger: ledger,
                                                   strategy: .init(pricing: .scaled(baseRate: 0.20, surge: nil)))
        let earnings     = gita.documentEarnings(from: priced)

        let earningTotal = earnings.values.reduce(0.0, +)
        XCTAssertEqual(earningTotal, priced.totalPayout, accuracy: 1e-9,
            "sum of document earnings must equal totalPayout when there is no self-referential spender")
    }

    func testDocumentEarningsExcludesSelfReferentialSpender() {
        // alice spends and owns docA — her earning must NOT flow into documentEarnings.
        let partitions = [
            makePartition(documentId: "docA", ownerId: "alice", text: "one two three four"),
            makePartition(documentId: "docB", ownerId: "bob",   text: "five six"),
        ]
        let contribution = gita.royalty(for: partitions)
        let ledger       = Gita.TokenLedger.test()
        let request      = SeerRequest(ownerId: "alice", group: nil, aggregate: nil, scope: nil, requestID: nil)
        let priced       = gita.priceContribution(contribution, ledger: ledger,
                                                   strategy: .init(pricing: .scaled(baseRate: 0.20, surge: nil)),
                                                   request: request)
        let earnings     = gita.documentEarnings(from: priced)

        XCTAssertNil(earnings["docA"],
            "self-referential spender's document must not accumulate earnings")
        XCTAssertGreaterThan(earnings["docB"] ?? 0, 0,
            "non-spender document must still earn")
    }

    func testDocumentEarningsZeroWhenAllDocumentsSelfReferential() {
        // Spender owns every retrieved document — no credits flow anywhere.
        let partitions = [
            makePartition(documentId: "docA", ownerId: "alice", text: "one two three"),
            makePartition(documentId: "docB", ownerId: "alice", text: "four five six"),
        ]
        let contribution = gita.royalty(for: partitions)
        let ledger       = Gita.TokenLedger.test()
        let request      = SeerRequest(ownerId: "alice", group: nil, aggregate: nil, scope: nil, requestID: nil)
        let priced       = gita.priceContribution(contribution, ledger: ledger,
                                                   strategy: .init(pricing: .scaled(baseRate: 0.20, surge: nil)),
                                                   request: request)
        let earnings     = gita.documentEarnings(from: priced)

        XCTAssertTrue(earnings.isEmpty,
            "documentEarnings must be empty when every retrieved document belongs to the spender")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: 9 — TokenLedger.merge
    // ─────────────────────────────────────────────────────────────────────────

    func testMergeEmptyIntoEmptyRemainsEmpty() {
        var base = Gita.TokenLedger()
        base.merge(Gita.TokenLedger())
        XCTAssertTrue(base.isEmpty)
        XCTAssertEqual(base.totalTokens, 0)
    }

    func testMergeNonEmptyIntoEmpty() {
        var base = Gita.TokenLedger()
        let other = Gita.TokenLedger.test(model: "mistral-tiny", promptTokens: 80, completionTokens: 20)
        base.merge(other)
        XCTAssertEqual(base.lines.count, 1)
        XCTAssertEqual(base.totalPromptTokens,     80)
        XCTAssertEqual(base.totalCompletionTokens, 20)
    }

    func testMergeAddsLineCount() {
        var base  = Gita.TokenLedger.test()          // 1 line: mistral-medium 100/50
        let extra = Gita.TokenLedger.twoCall          // 2 lines
        base.merge(extra)
        XCTAssertEqual(base.lines.count, 3)
    }

    func testMergeTotalTokensAccumulate() {
        // base: 100 prompt + 50 completion = 150
        // extra: mistral-tiny 80/20 = 100
        var base = Gita.TokenLedger.test(model: "mistral-medium", promptTokens: 100, completionTokens: 50)
        var extra = Gita.TokenLedger()
        extra.record(model: "mistral-tiny", promptTokens: 80, completionTokens: 20)
        base.merge(extra)
        XCTAssertEqual(base.totalPromptTokens,     180)
        XCTAssertEqual(base.totalCompletionTokens, 70)
        XCTAssertEqual(base.totalTokens,           250)
    }

    func testMergeTotalCreditsEqualsSum() {
        var base  = Gita.TokenLedger.test()
        let extra = Gita.TokenLedger.test(model: "mistral-tiny", promptTokens: 200, completionTokens: 100)
        let expectedCredits = base.totalCredits + extra.totalCredits
        base.merge(extra)
        XCTAssertEqual(base.totalCredits, expectedCredits, accuracy: 1e-12,
            "merged totalCredits must equal the sum of both ledgers' credits")
    }

    func testMergeIsIdempotentOnOriginal() {
        // merging should not modify the `other` ledger
        let base  = Gita.TokenLedger.test()
        var copy  = base
        let extra = Gita.TokenLedger.test(model: "mistral-tiny", promptTokens: 50, completionTokens: 25)
        copy.merge(extra)
        // `extra` is unchanged
        XCTAssertEqual(extra.lines.count, 1)
        XCTAssertEqual(extra.totalTokens, 75)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: 10 — Sinatra ledger integration with priceContribution
    // ─────────────────────────────────────────────────────────────────────────

    /// Simulates the production billing path:
    ///   primaryLedger (mistral-medium) + sinatraLedger (mistral-tiny) merged
    ///   → priceContribution sees the combined cost.
    func testMergedLedgerInflatesTotalCost() {
        let contribution   = twoOwnerContribution()
        var primaryLedger  = Gita.TokenLedger.test(model: "mistral-medium",
                                                    promptTokens: 1000, completionTokens: 300)
        var sinatraLedger  = Gita.TokenLedger()
        sinatraLedger.record(model: "mistral-tiny", promptTokens: 400, completionTokens: 200)

        let primaryOnly = gita.priceContribution(contribution, ledger: primaryLedger,
                                                  strategy: .init(pricing: .scaled(baseRate: 0.20, surge: nil)))
        primaryLedger.merge(sinatraLedger)
        let merged     = gita.priceContribution(contribution, ledger: primaryLedger,
                                                 strategy: .init(pricing: .scaled(baseRate: 0.20, surge: nil)))

        XCTAssertGreaterThan(merged.totalCost, primaryOnly.totalCost,
            "merged ledger must produce a higher total cost than primary-only")
        XCTAssertGreaterThan(merged.totalPayout, primaryOnly.totalPayout,
            "merged ledger must produce higher owner payouts")
    }

    func testMergedLedgerInvariantStillHolds() {
        // totalPayout + serviceCharge == totalCost must hold after merge.
        let contribution  = twoOwnerContribution()
        var ledger        = Gita.TokenLedger.test(model: "mistral-medium",
                                                   promptTokens: 800, completionTokens: 250)
        var sinatraLedger = Gita.TokenLedger()
        sinatraLedger.record(model: "mistral-tiny", promptTokens: 300, completionTokens: 150)
        ledger.merge(sinatraLedger)

        let priced = gita.priceContribution(contribution, ledger: ledger)
        XCTAssertEqual(priced.totalPayout + priced.serviceCharge, priced.totalCost, accuracy: 1e-9,
            "invariant must hold after merging primary + Sinatra ledgers")
    }

    func testSinatraOnlyLedgerPricedAlone() {
        // Edge case: if primary generation produces zero tokens (e.g. cached response),
        // Sinatra's cost alone should still satisfy the invariant.
        let contribution = twoOwnerContribution()
        var ledger       = Gita.TokenLedger()
        ledger.record(model: "mistral-tiny", promptTokens: 400, completionTokens: 200)

        let priced = gita.priceContribution(contribution, ledger: ledger,
                                             strategy: .init(pricing: .scaled(baseRate: 0.20, surge: nil)))
        XCTAssertGreaterThan(priced.totalCost, 0, "Sinatra-only cost must be > 0")
        XCTAssertEqual(priced.totalPayout + priced.serviceCharge, priced.totalCost, accuracy: 1e-9)
    }

    func testEmptySinatraLedgerMergeDoesNotChangeCost() {
        // If Sinatra returns an empty ledger (early exit), billing must be identical
        // to primary-only pricing.
        let contribution = twoOwnerContribution()
        var ledger       = Gita.TokenLedger.test()
        let baseline     = gita.priceContribution(contribution, ledger: ledger,
                                                   strategy: .init(pricing: .scaled(baseRate: 0.20, surge: nil)))
        ledger.merge(Gita.TokenLedger())   // merge empty — should be no-op
        let afterMerge = gita.priceContribution(contribution, ledger: ledger,
                                                 strategy: .init(pricing: .scaled(baseRate: 0.20, surge: nil)))

        XCTAssertEqual(baseline.totalCost, afterMerge.totalCost, accuracy: 1e-12,
            "merging an empty Sinatra ledger must not change the cost")
    }
}
