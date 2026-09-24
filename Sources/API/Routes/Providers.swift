//
//  Providers.swift
//  Sewn
//
//  WHAT: What backends this Sewn can actually serve, and a way to warm the
//        on-device one before a turn waits on it.
//  OUT:  GET /v1/providers, POST /v1/providers/local/warm,
//        GET /v1/providers/local/sinatra/traces/{id}, GET /v1/providers/local/sinatra/analysis
//  PIN:  Honest about absence. A provider with no key, or an on-device build
//        with no Metal library, reports `available: false` WITH THE REASON —
//        the client shows it rather than discovering it as a failed turn.
//

import Foundation
import HTTPTypes
import Hummingbird
import NIOCore

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
    /// SinatraHarness for the signed-in owner — the local row only.
    var sinatra: SinatraStatusInfo?

    enum CodingKeys: String, CodingKey {
        case id, available, state, progress, model, capabilities, reason, sinatra
        case displayName = "display_name"
        case isDefault = "default"
    }
}

struct ProvidersResponse: Codable, ResponseEncodable {
    var providers: [ProviderInfo]
    var `default`: String
}

/// Optional body of `POST /v1/providers/local/warm`: the model the client will ask for.
struct ProviderWarmRequest: Codable {
    var model: String?
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
    localBuilt: Bool,
    sinatra: SinatraStatusInfo? = nil
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
        reason: reason,
        sinatra: provider == .local ? sinatra : nil)
}

func registerProvidersRoutes(
    _ router: some RouterMethods<SewnRequestContext>,
    modelProvider: ModelProvider
) {
    router.get("/v1/providers") { _, context async throws -> ProvidersResponse in
        let state = await modelProvider.local.snapshot()
        let built = await modelProvider.local.isBuilt
        var sinatra: SinatraStatusInfo?
        if built, let owner = context.authUserId?.lowercased() {
            sinatra = await modelProvider.local.sinatraStatus(owner: owner)
        }
        return ProvidersResponse(
            providers: LLMProvider.allCases.map {
                providerInfo($0, localState: state, localBuilt: built, sinatra: sinatra)
            },
            default: LLMProvider.serverDefault.rawValue)
    }

    /// Load the on-device model now, so the first turn does not pay for it.
    /// Idempotent: a warm already in flight is joined, not restarted.
    /// A body `{"model": "<hub id>"}` warms the model the client will ask for (Ambient's
    /// chat-model field) instead of the configured default.
    router.post("/v1/providers/local/warm") { request, context async throws -> ProviderWarmResponse in
        let built = await modelProvider.local.isBuilt
        guard built else {
            throw HTTPError(
                .serviceUnavailable, message: ProviderUnavailable.localNotBuilt.description)
        }
        var model = ModelConfig.chatModel(for: .local)
        if let body = try? await request.decode(as: ProviderWarmRequest.self, context: context),
            let requested = body.model, !requested.isEmpty
        {
            guard ModelConfig.accepts(requested, provider: .local) else {
                throw HTTPError(.badRequest, message: "\(requested) is not an on-device model id.")
            }
            model = requested
        }
        context.logger.info("[Providers] warming on-device \(model)")
        let local = modelProvider.local
        Task { await local.warm(modelID: model) }
        let state = await local.snapshot()
        return ProviderWarmResponse(accepted: true, state: state.name, model: model)
    }

    /// One of the caller's SinatraHarness traces: how the injection moved the logits, and what
    /// the retrieved context did to the answer, step by step.
    router.get("/v1/providers/local/sinatra/traces/:traceId") { _, context async throws -> Response in
        guard let owner = context.authUserId?.lowercased() else { throw HTTPError(.unauthorized) }
        guard let raw = context.parameters.get("traceId"), let id = UUID(uuidString: raw) else {
            throw HTTPError(.badRequest, message: "traceId must be a UUID.")
        }
        guard let data = await modelProvider.local.traceJSON(owner: owner, turnId: id) else {
            throw HTTPError(.notFound, message: "No SinatraHarness trace \(raw) for this account.")
        }
        return sinatraJSONResponse(data)
    }

    /// Grounding over the caller's band: whether steering reduced drift, the first half of
    /// the band against the second, and which documents the answers cite.
    router.get("/v1/providers/local/sinatra/analysis") { _, context async throws -> Response in
        guard let owner = context.authUserId?.lowercased() else { throw HTTPError(.unauthorized) }
        guard let data = await modelProvider.local.analysisJSON(owner: owner) else {
            throw HTTPError(.notFound, message: "No on-device model is loaded.")
        }
        return sinatraJSONResponse(data)
    }
}

private func sinatraJSONResponse(_ data: Data) -> Response {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
}
