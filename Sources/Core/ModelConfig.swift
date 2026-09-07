//
//  ModelConfig.swift
//  Seer
//
//  Runtime-mutable model selection, keyed by LLMProvider. Every route asks
//  for the model of a (provider, job) pair; nothing infers a provider from a
//  model name any more.
//

import Foundation

/// Which model serves each job for each provider. Seeded from the environment
//  at boot, mutable at runtime via `PUT /v1/admin/model` so a freshly trained
//  `tinker://…` checkpoint can be deployed without a server restart.
enum ModelConfig {
    /// On-device default. The same Hub id Mary used to load in-process, so
    /// a machine that already downloaded it pays nothing to switch.
    static let defaultLocalModel = "mlx-community/Mistral-Nemo-Instruct-2407-4bit"
    static let defaultTinkerModel = "thinkingmachines/Inkling"
    static let defaultMistralModel = "mistral-medium-latest"

    /// Internal one-shot generations (compact, Sinatra sentiment, auto-memory,
    /// summarize) run on a fast, non-thinking model. Inkling must never double
    /// as the utility model: it deliberates for 30–90s per call, which stacked
    /// into minutes of chat latency — so Tinker borrows Mistral's here.
    static let defaultUtilityModel = "mistral-tiny"

    /// True when the model name belongs to the Mistral API family. Still the
    /// family check `resolveChatModel` uses to police a client's request; it
    /// is no longer how a provider is chosen.
    static func isMistralModel(_ model: String) -> Bool {
        let lowered = model.lowercased()
        return lowered.hasPrefix("mistral") || lowered.hasPrefix("open-mi")
            || lowered.hasPrefix("ministral") || lowered.hasPrefix("codestral")
    }

    private static func environment(_ key: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty
        else { return nil }
        return value
    }

    /// Runtime overrides from `PUT /v1/admin/model`. Empty = follow the env.
    private static let overrides = LockedValue<(chat: String, utility: String)>(("", ""))

    /// The chat model for one provider.
    static func chatModel(for provider: LLMProvider) -> String {
        let override = overrides.withLock { $0.chat }
        if !override.isEmpty, accepts(override, provider: provider) { return override }
        switch provider {
        case .mistral:
            return environment("SEER_CHAT_MODEL").flatMap {
                isMistralModel($0) ? $0 : nil
            } ?? defaultMistralModel
        case .tinker:
            return environment("TINKER_MODEL") ?? defaultTinkerModel
        case .local:
            return environment("SEER_LOCAL_MODEL") ?? defaultLocalModel
        }
    }

    /// The utility model for one provider. Hosted providers share Mistral's
    /// fast one; local has only its own.
    static func utilityModel(for provider: LLMProvider) -> String {
        let override = overrides.withLock { $0.utility }
        if !override.isEmpty { return override }
        switch provider {
        case .mistral, .tinker:
            return environment("UTILITY_MODEL") ?? defaultUtilityModel
        case .local:
            return chatModel(for: .local)
        }
    }

    /// Pair-coding synthesis for `/v1/code/complete`. Mary does not send a
    /// model id; this is Seer's pin.
    static func codingModel(for provider: LLMProvider) -> String {
        switch provider {
        case .mistral:
            return environment("SEER_CODING_MODEL") ?? defaultCodingModel
        case .tinker:
            return chatModel(for: .tinker)
        case .local:
            return environment("SEER_LOCAL_CODING_MODEL") ?? chatModel(for: .local)
        }
    }

    /// The provider that could serve this model id, by family. A request may
    /// name a model, but only one belonging to the provider it selected —
    /// otherwise a `tinker://` id would be posted to Mistral's API.
    static func accepts(_ model: String, provider: LLMProvider) -> Bool {
        switch provider {
        case .mistral:
            return isMistralModel(model)
        case .tinker:
            return model.hasPrefix("tinker://") || model.contains("/")
        case .local:
            return model.contains("/") && !model.hasPrefix("tinker://")
        }
    }

    static func update(chatModel: String? = nil, utilityModel: String? = nil) {
        overrides.withLock {
            if let chatModel { $0.chat = chatModel }
            if let utilityModel { $0.utility = utilityModel }
        }
    }

    /// What `GET /v1/admin/model` reports: the server-default provider's pair.
    static var chatModel: String { chatModel(for: .serverDefault) }
    static var utilityModel: String { utilityModel(for: .serverDefault) }

    /// A client-supplied `model` is honored only when it belongs to the
    /// provider serving the request; anything else falls back to that
    /// provider's configured chat model.
    static func resolveChatModel(requested: String?, provider: LLMProvider) -> String {
        guard let requested, !requested.isEmpty else { return chatModel(for: provider) }
        return accepts(requested, provider: provider) ? requested : chatModel(for: provider)
    }

    /// The vision model serving `/v1/vision/look`; override with
    /// `VISION_MODEL` in `.env`. The Pixtral ids are RETIRED (the API answers
    /// `invalid_model`, live-verified 2026-08-11) — vision now rides the
    /// multimodal mainline; medium is the same family the chat lane uses.
    static var visionModel: String {
        ProcessInfo.processInfo.environment["VISION_MODEL"] ?? "mistral-medium-latest"
    }

    // MARK: - Realtime opening pass

    /// Model that speaks the realtime route's instant opening while retrieval
    /// and the grounded pass run. Must be fast and non-thinking — the opening
    /// exists to cover the primary model's deliberation, so routing it through
    /// a thinking model would defeat the point. `mistral-small-latest` over
    /// `utilityModel` (mistral-tiny): the opening is user-visible prose, not an
    /// extraction job.
    static var openingModel: String {
        ProcessInfo.processInfo.environment["SEER_REALTIME_OPENING_MODEL"]
            ?? "mistral-small-latest"
    }

    static let defaultCodingModel = "codestral-latest"

    /// The opening is one-to-two sentences; a tight budget keeps a rambling
    /// generation from delaying the grounded continuation.
    static let openingMaxTokens = 80

    /// Reasoning models spend a large share of their token budget thinking
    /// before the answer. Worse, when Tinker truncates one at `max_tokens`
    /// mid-reasoning it returns the partial deliberation as a `text` block
    /// (non-stream) or streams nothing at all — which would leak straight to
    /// the user or produce an empty reply. Floor the budget high enough that
    /// the model reaches its actual answer; Inkling has been observed to
    /// deliberate past 2k tokens on instruction-heavy chat prompts.
    static let thinkingTokenFloor = 4_096

    /// True for models that emit thinking before their response (Inkling, any
    /// tinker:// checkpoint, and Qwen3 hybrids without the `/no_think` switch).
    static func isThinkingModel(_ model: String) -> Bool {
        model.localizedCaseInsensitiveContains("inkling")
            || model.hasPrefix("tinker://")
            || supportsNoThinkSwitch(model)
    }

    /// Qwen3 hybrid models honor a `/no_think` soft switch in the prompt that
    /// suppresses deliberation entirely (the 2507 instruct variants dropped it).
    static func supportsNoThinkSwitch(_ model: String) -> Bool {
        model.localizedCaseInsensitiveContains("qwen3")
            && !model.contains("2507")
    }

    /// The effective max-token budget for a chat generation: the requested
    /// value, floored for thinking models.
    static func chatMaxTokens(requested: Int?, model: String) -> Int {
        let requested = requested ?? GenerationDefaults.maxTokens
        guard isThinkingModel(model) else { return requested }
        return max(requested, thinkingTokenFloor)
    }
}
