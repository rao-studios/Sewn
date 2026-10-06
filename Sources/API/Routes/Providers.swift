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
//        Reachable without an account on a local stack (LocalOnlyGrant):
//        the caller is then owner "local-<app>".
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
/// `load: false` only makes it the Mac's on-device model, without loading it (a client
/// whose replies are hosted still chose the model its on-device jobs run).
struct ProviderWarmRequest: Codable {
    var model: String?
    var load: Bool?
}

struct ProviderWarmResponse: Codable, ResponseEncodable {
    var accepted: Bool
    var state: String
    var model: String
}

/// One model's place on this Mac (`GET /v1/providers/local/models`).
struct LocalModelInfo: Codable, ResponseEncodable, Equatable {
    var id: String
    /// "absent" | "downloading" | "installed" | "failed"
    var state: String
    /// 0…1 while downloading.
    var progress: Double?
    var reason: String?

    init(id: String, disk: LocalModelDisk) {
        self.id = id
        self.state = disk.name
        switch disk {
        case .downloading(let fraction): progress = fraction
        case .failed(let reason): self.reason = reason
        case .absent, .installed: break
        }
    }
}

struct LocalModelsResponse: Codable, ResponseEncodable {
    var models: [LocalModelInfo]
}

/// Body of `POST /v1/providers/local/download` and `…/local/remove`.
struct LocalModelRequest: Codable {
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
        let body = try? await request.decode(as: ProviderWarmRequest.self, context: context)
        if let requested = body?.model, !requested.isEmpty {
            guard ModelConfig.accepts(requested, provider: .local) else {
                throw HTTPError(.badRequest, message: "\(requested) is not an on-device model id.")
            }
            model = requested
            // The client's choice is the Mac's on-device model: every local job follows it.
            ModelConfig.chooseLocalModel(requested)
        }
        let local = modelProvider.local
        if body?.load == false {
            context.logger.info("[Providers] on-device model is now \(model) (not loaded)")
        } else {
            context.logger.info("[Providers] warming on-device \(model)")
            Task { await local.warm(modelID: model) }
        }
        let state = await local.snapshot()
        return ProviderWarmResponse(accepted: true, state: state.name, model: model)
    }

    /// Which of these on-device models are on this Mac: `?ids=org/a,org/b`.
    router.get("/v1/providers/local/models") { request, _ async throws -> LocalModelsResponse in
        let ids = (request.uri.queryParameters.get("ids") ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var models: [LocalModelInfo] = []
        for id in ids.prefix(16) {
            guard (try? LocalModelStoreError.validated(id)) != nil else {
                throw HTTPError(.badRequest, message: LocalModelStoreError.invalidID(id).description)
            }
            models.append(LocalModelInfo(id: id, disk: await modelProvider.localModels.disk(id)))
        }
        return LocalModelsResponse(models: models)
    }

    /// Fetch an on-device model without loading it. Joins a download already running;
    /// progress reads back from `GET /v1/providers/local/models`.
    router.post("/v1/providers/local/download") { request, context async throws -> LocalModelInfo in
        let body = try await request.decode(as: LocalModelRequest.self, context: context)
        do {
            try await modelProvider.localModels.download(body.model)
        } catch let error as LocalModelStoreError {
            throw HTTPError(error == .unavailable ? .serviceUnavailable : .badRequest, message: error.description)
        }
        return LocalModelInfo(id: body.model, disk: await modelProvider.localModels.disk(body.model))
    }

    /// Delete an on-device model from this Mac. Refused for the model in use or loading,
    /// and for the default, which other apps expect on disk.
    router.post("/v1/providers/local/remove") { request, context async throws -> LocalModelInfo in
        let body = try await request.decode(as: LocalModelRequest.self, context: context)
        var inUse: Set<String> = [ModelConfig.chatModel(for: .local)]
        switch await modelProvider.local.snapshot() {
        case .ready(let loaded): inUse.insert(loaded)
        case .loading: inUse.insert(body.model)  // which model is loading is not reported: refuse
        case .cold, .failed: break
        }
        do {
            try await modelProvider.localModels.remove(
                body.model, inUse: inUse, kept: ModelConfig.defaultLocalModel)
        } catch let error as LocalModelStoreError {
            switch error {
            case .invalidID: throw HTTPError(.badRequest, message: error.description)
            case .unavailable: throw HTTPError(.serviceUnavailable, message: error.description)
            case .inUse, .keptModel, .downloading: throw HTTPError(.conflict, message: error.description)
            }
        }
        context.logger.info("[Providers] removed on-device \(body.model)")
        return LocalModelInfo(id: body.model, disk: await modelProvider.localModels.disk(body.model))
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
