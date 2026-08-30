//
//  ModelConfig.swift
//  Seer
//
//  Runtime-mutable model selection for the global LLM provider (Mistral or
//  ThinkingMachines/Tinker — see NetworkService.BaseEndpoint.globalLLM).
//

import Foundation

/// Which model serves chat and utility generations. Seeded from the
/// environment at boot, mutable at runtime via `PUT /v1/admin/model` so the
/// client app can deploy a freshly trained `tinker://…` checkpoint (or pin a
/// different Mistral model) without a server restart.
enum ModelConfig {
    /// Follows `NetworkService.BaseEndpoint.globalLLM` (env-driven, defaults
    /// to Mistral): Tinker checkpoints only make sense as the default when
    /// Tinker is the configured provider.
    static var defaultModel: String {
        NetworkService.BaseEndpoint.globalLLM == .tinker
            ? "thinkingmachines/Inkling" : "mistral-medium-latest"
    }

    /// Internal one-shot generations (compact, Sinatra sentiment, auto-memory,
    /// summarize) run on the Mistral API — fast, non-thinking, and cheap.
    /// Inkling must never double as the utility model: it deliberates for
    /// 30–90s per call, which stacked into minutes of chat latency.
    static let defaultUtilityModel = "mistral-tiny"

    /// True when the model name belongs to the Mistral API family — routes
    /// utility calls to the Mistral chat-completions endpoint instead of
    /// Tinker's Anthropic-compatible surface.
    static func isMistralModel(_ model: String) -> Bool {
        let lowered = model.lowercased()
        return lowered.hasPrefix("mistral") || lowered.hasPrefix("open-mi")
            || lowered.hasPrefix("ministral") || lowered.hasPrefix("codestral")
    }

    /// `TINKER_MODEL` only seeds the chat model when Tinker is the configured
    /// provider — a leftover `TINKER_MODEL` in `.env` must not silently
    /// override the Mistral default when `SEER_GLOBAL_LLM` says otherwise.
    private static let state = LockedValue<(chat: String, utility: String)>((
        chat: ProcessInfo.processInfo.environment["SEER_CHAT_MODEL"]
            ?? (NetworkService.BaseEndpoint.globalLLM == .tinker
                ? ProcessInfo.processInfo.environment["TINKER_MODEL"]
                : nil)
            ?? defaultModel,
        // Provider-neutral: a Mistral utility model name works out of the box
        // (isMistralModel routes it to the Mistral chat-completions path
        // below), and a tinker:// override works too.
        utility: ProcessInfo.processInfo.environment["UTILITY_MODEL"]
            ?? defaultUtilityModel
    ))

    /// Model used for user-facing chat completions.
    static var chatModel: String { state.withLock { $0.chat } }

    /// Model used for internal one-shot generations (Sinatra sentiment,
    /// Marielle, summarize, auto-memory).
    static var utilityModel: String { state.withLock { $0.utility } }

    /// The vision model serving `/v1/vision/look`; override with
    /// `VISION_MODEL` in `.env`. The Pixtral ids are RETIRED (the API answers
    /// `invalid_model`, live-verified 2026-08-11) — vision now rides the
    /// multimodal mainline; medium is the same family the chat lane uses.
    static var visionModel: String {
        ProcessInfo.processInfo.environment["VISION_MODEL"] ?? "mistral-medium-latest"
    }

    static func update(chatModel: String? = nil, utilityModel: String? = nil) {
        state.withLock {
            if let chatModel, !chatModel.isEmpty { $0.chat = chatModel }
            if let utilityModel, !utilityModel.isEmpty { $0.utility = utilityModel }
        }
    }

    /// A client-supplied `model` field is honored when it references a Tinker
    /// checkpoint or an explicit provider model; placeholder names fall back
    /// to the configured chat model.
    static func resolveChatModel(requested: String?) -> String {
        guard let requested, !requested.isEmpty else { return chatModel }
        if requested.hasPrefix("tinker://") || requested.contains("/")
            || isMistralModel(requested) { return requested }
        return chatModel
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

    /// Pair-coding synthesis for `/v1/code/complete`. Mary does not send a
    /// model id; this is Seer's pin. Override with `SEER_CODING_MODEL`.
    static let defaultCodingModel = "codestral-latest"
    static var codingModel: String {
        let override = ProcessInfo.processInfo.environment["SEER_CODING_MODEL"]
        if let override, !override.isEmpty { return override }
        return defaultCodingModel
    }

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
