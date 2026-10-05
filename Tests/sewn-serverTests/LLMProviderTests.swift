//
//  LLMProviderTests.swift
//  sewn-serverTests
//
//  The provider enum, its wire values, and the per-provider model tables.
//  These raw values are shared with Mary's LLMEngineChoice — a rename here
//  silently reroutes every one of her turns.
//

import XCTest
@testable import sewn_server

final class LLMProviderTests: XCTestCase {

    func testRawValuesAreTheWireContractWithMary() {
        XCTAssertEqual(LLMProvider.allCases.map(\.rawValue), ["mistral", "tinker", "local"])
        XCTAssertEqual(LLMProvider(rawValue: "hosted"), nil)
    }

    func testOnlyLocalHasNoHostedTransport() {
        XCTAssertEqual(LLMProvider.mistral.hostedBase, .mistral)
        XCTAssertEqual(LLMProvider.tinker.hostedBase, .tinker)
        XCTAssertNil(LLMProvider.local.hostedBase)
        XCTAssertTrue(LLMProvider.local.isLocal)
    }

    func testAMissingKeyIsAnAnswerNotACrash() {
        // The whole point of apiKeyIfPresent: a client may select a provider
        // whose key was never configured, and the server must survive saying so.
        XCTAssertNoThrow(NetworkService.BaseEndpoint.tinker.apiKeyIfPresent)
        XCTAssertEqual(NetworkService.BaseEndpoint.tinker.apiKeyEnvVar, "TINKER_API_KEY")
        XCTAssertEqual(NetworkService.BaseEndpoint.mistral.apiKeyEnvVar, "MISTRAL_API_KEY")
    }
}

final class ModelConfigProviderTests: XCTestCase {

    override func tearDown() {
        ModelConfig.chooseLocalModel(nil)
        super.tearDown()
    }

    /// Settings › On-device in Ambient: the chosen model is every local job's model, so the
    /// harness never swaps between it and the default mid-turn.
    func testAChosenOnDeviceModelRunsEveryLocalJob() {
        let small = "mlx-community/Mistral-Small-3.2-24B-Instruct-2506-4bit"
        ModelConfig.chooseLocalModel(small)
        XCTAssertEqual(ModelConfig.chatModel(for: .local), small)
        XCTAssertEqual(ModelConfig.utilityModel(for: .local), small)
        XCTAssertEqual(ModelConfig.resolveChatModel(requested: nil, provider: .local), small)
        // Hosted lanes never see it.
        XCTAssertEqual(ModelConfig.resolveChatModel(requested: nil, provider: .mistral), ModelConfig.chatModel(for: .mistral))
        XCTAssertNotEqual(ModelConfig.utilityModel(for: .mistral), small)
    }

    func testAHostedNameIsNeverChosenAndNilClearsTheChoice() {
        ModelConfig.chooseLocalModel("mlx-community/Ministral-3-8B-Instruct-2512-4bit")
        ModelConfig.chooseLocalModel("mistral-medium-latest")
        XCTAssertEqual(ModelConfig.chatModel(for: .local), "mlx-community/Ministral-3-8B-Instruct-2512-4bit")
        ModelConfig.chooseLocalModel(nil)
        XCTAssertEqual(ModelConfig.chatModel(for: .local),
                       ProcessInfo.processInfo.environment["SEWN_LOCAL_MODEL"] ?? ModelConfig.defaultLocalModel)
    }

    func testOnlyAPlainHubIDReachesTheDisk() {
        XCTAssertNoThrow(try LocalModelStoreError.validated("mlx-community/Mistral-Nemo-Instruct-2407-4bit"))
        for bad in ["../etc", "mlx-community/../../x", "a/b/c", "/abs/path", "noslash", "org/", "org/.hidden"] {
            XCTAssertThrowsError(try LocalModelStoreError.validated(bad), bad)
        }
    }

    func testEachProviderHasItsOwnChatModelFamily() {
        XCTAssertTrue(ModelConfig.isMistralModel(ModelConfig.chatModel(for: .mistral)))
        XCTAssertTrue(ModelConfig.chatModel(for: .local).contains("/"))
        XCTAssertFalse(ModelConfig.isMistralModel(ModelConfig.chatModel(for: .local)))
    }

    /// The bug this design exists to close: a `tinker://` id must never be
    /// posted to Mistral's host just because the client asked for it.
    func testARequestedModelIsRefusedWhenItBelongsToAnotherProvider() {
        XCTAssertEqual(
            ModelConfig.resolveChatModel(requested: "tinker://run/42", provider: .mistral),
            ModelConfig.chatModel(for: .mistral))
        XCTAssertEqual(
            ModelConfig.resolveChatModel(requested: "mistral-large-latest", provider: .tinker),
            ModelConfig.chatModel(for: .tinker))
        XCTAssertEqual(
            ModelConfig.resolveChatModel(requested: "tinker://run/42", provider: .tinker),
            "tinker://run/42")
        XCTAssertEqual(
            ModelConfig.resolveChatModel(requested: "mistral-large-latest", provider: .mistral),
            "mistral-large-latest")
    }

    func testAnEmptyRequestFallsBackToTheProvidersOwnModel() {
        for provider in LLMProvider.allCases {
            XCTAssertEqual(
                ModelConfig.resolveChatModel(requested: nil, provider: provider),
                ModelConfig.chatModel(for: provider))
            XCTAssertEqual(
                ModelConfig.resolveChatModel(requested: "", provider: provider),
                ModelConfig.chatModel(for: provider))
        }
    }

    /// Inkling deliberates for 30–90s; it must never serve an extraction job.
    func testTinkerBorrowsMistralsUtilityModelAndLocalUsesItsOwn() {
        XCTAssertEqual(ModelConfig.utilityModel(for: .tinker), ModelConfig.defaultUtilityModel)
        XCTAssertEqual(ModelConfig.utilityModel(for: .mistral), ModelConfig.defaultUtilityModel)
        XCTAssertEqual(ModelConfig.utilityModel(for: .local), ModelConfig.chatModel(for: .local))
    }

    func testCodingPinsCodestralForMistralAndStaysOnDeviceForLocal() {
        XCTAssertEqual(ModelConfig.codingModel(for: .mistral), ModelConfig.defaultCodingModel)
        XCTAssertTrue(ModelConfig.isMistralModel(ModelConfig.codingModel(for: .mistral)))
        XCTAssertEqual(ModelConfig.codingModel(for: .local), ModelConfig.chatModel(for: .local))
    }
}
