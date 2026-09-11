//
//  Providers.swift
//  Sewn
//
//  WHAT: What backends this Sewn can actually serve, and a way to warm the
//        on-device one before a turn waits on it.
//  OUT:  GET /v1/providers, POST /v1/providers/local/warm
//  PIN:  Honest about absence. A provider with no key, or an on-device build
//        with no Metal library, reports `available: false` WITH THE REASON —
//        the client shows it rather than discovering it as a failed turn.
//

import Foundation
import Hummingbird

struct ProviderCapabilities: Codable, ResponseEncodable {
    var chat: Bool
    var skills: Bool
    var code: Bool
    var complete: Bool
    /// Vision, embeddings and speech are Mistral-served for every provider.
    var vision: Bool
    var embeddings: Bool
    var speech: Bool
}

struct ProviderInfo: Codable, ResponseEncodable {
    var id: String
    var displayName: String
    var available: Bool
    var isDefault: Bool
    var state: String
    var progress: Double?
    var model: String
    var capabilities: ProviderCapabilities
    var reason: String?

    enum CodingKeys: String, CodingKey {
        case id, available, state, progress, model, capabilities, reason
        case displayName = "display_name"
        case isDefault = "default"
    }
}

struct ProvidersResponse: Codable, ResponseEncodable {
    var providers: [ProviderInfo]
    var `default`: String
}

struct ProviderWarmResponse: Codable, ResponseEncodable {
    var accepted: Bool
    var state: String
    var model: String
}

/// One provider's row. Hosted availability is "is the key here"; local is
/// "was this built with MLX, and is the Metal library beside the binary".
func providerInfo(
    _ provider: LLMProvider,
    localState: LocalState,
    localBuilt: Bool
) -> ProviderInfo {
    let hostedCapabilities = ProviderCapabilities(
        chat: true, skills: true, code: true, complete: true,
        vision: false, embeddings: false, speech: false)
    var available = true
    var reason: String?
    var state = "ready"

    switch provider {
    case .mistral, .tinker:
        if let base = provider.hostedBase, base.apiKeyIfPresent == nil {
            available = false
            state = "unconfigured"
            reason = ProviderUnavailable.missingKey(envVar: base.apiKeyEnvVar).description
        }
    case .local:
        state = localState.name
        if !localBuilt {
            available = false
            reason = ProviderUnavailable.localNotBuilt.description
        } else if !LocalGPU.report().isSatisfied {
            available = false
            state = "failed"
            reason = LocalGPU.remedy()
        } else {
            reason = localState.reason
            if localState.reason != nil { available = false }
        }
    }

    return ProviderInfo(
        id: provider.rawValue,
        displayName: provider.displayName,
        available: available,
        isDefault: provider == .serverDefault,
        state: state,
        progress: localState.fraction.flatMap { provider == .local ? $0 : nil },
        model: ModelConfig.chatModel(for: provider),
        capabilities: hostedCapabilities,
        reason: reason)
}

func registerProvidersRoutes(
    _ router: some RouterMethods<SewnRequestContext>,
    modelProvider: ModelProvider
) {
    router.get("/v1/providers") { _, _ async throws -> ProvidersResponse in
        let state = await modelProvider.local.snapshot()
        let built = await modelProvider.local.isBuilt
        return ProvidersResponse(
            providers: LLMProvider.allCases.map {
                providerInfo($0, localState: state, localBuilt: built)
            },
            default: LLMProvider.serverDefault.rawValue)
    }

    /// Load the on-device model now, so the first turn does not pay for it.
    /// Idempotent: a warm already in flight is joined, not restarted.
    router.post("/v1/providers/local/warm") { _, context async throws -> ProviderWarmResponse in
        let built = await modelProvider.local.isBuilt
        guard built else {
            throw HTTPError(
                .serviceUnavailable, message: ProviderUnavailable.localNotBuilt.description)
        }
        let model = ModelConfig.chatModel(for: .local)
        context.logger.info("[Providers] warming on-device \(model)")
        let local = modelProvider.local
        Task { await local.warm(modelID: model) }
        let state = await local.snapshot()
        return ProviderWarmResponse(accepted: true, state: state.name, model: model)
    }
}
