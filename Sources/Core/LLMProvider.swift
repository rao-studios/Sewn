//
//  LLMProvider.swift
//  Seer
//
//  WHAT: Which backend answers a generation — the one enum every inference
//        route switches on. Clients send it per request (`provider`); absent,
//        the server default (`SEER_GLOBAL_LLM`) applies.
//  PIN:  Raw values are the wire, shared with Mary's LLMEngineChoice:
//        "mistral" | "tinker" | "local". Never rename a case.
//

import Foundation

enum LLMProvider: String, Codable, CaseIterable, Sendable {
    /// Mistral's hosted API (chat-completions wire).
    case mistral
    /// Thinking Machines' Tinker (Anthropic-compatible Messages wire).
    case tinker
    /// This machine, through Frigate MLX inside Seer.
    case local

    /// The provider a request gets when it names none. `SEER_GLOBAL_LLM`
    /// in `.env`; Mistral when unset or unknown.
    static var serverDefault: LLMProvider {
        LLMProvider(rawValue: ProcessInfo.processInfo.environment["SEER_GLOBAL_LLM"]?
            .lowercased() ?? "") ?? .mistral
    }

    /// The remote host, for hosted providers. Nil for local.
    var hostedBase: NetworkService.BaseEndpoint? {
        switch self {
        case .mistral: return .mistral
        case .tinker:  return .tinker
        case .local:   return nil
        }
    }

    var isLocal: Bool { self == .local }

    var displayName: String {
        switch self {
        case .mistral: return "Mistral (Hosted)"
        case .tinker:  return "Thinking Machines (Hosted)"
        case .local:   return "On-device"
        }
    }

    /// Internal one-shots (Sinatra, auto-memory, compaction, summarize) run
    /// on this machine only when opted in: on one GPU they serialize three to
    /// five extra generations behind every turn.
    static var localUtilityEnabled: Bool {
        ["1", "true", "yes"].contains(
            ProcessInfo.processInfo.environment["SEER_LOCAL_UTILITY"]?.lowercased() ?? "")
    }
}

/// A provider that cannot answer right now. Routes map this to 503 so a
/// mis-toggle is an error the client can read, never a crashed server.
enum ProviderUnavailable: Error, CustomStringConvertible, Equatable {
    case missingKey(envVar: String)
    case localNotBuilt
    case localFailed(String)
    case utilityDisabled(LLMProvider)

    var description: String {
        switch self {
        case .missingKey(let envVar):
            return "Missing \(envVar) — add it to Seer's .env or export it before starting Seer."
        case .localNotBuilt:
            return "This Seer build has no on-device backend (MLX is macOS-only)."
        case .localFailed(let reason):
            return "On-device model unavailable: \(reason)"
        case .utilityDisabled(let provider):
            return "Utility generations are off for \(provider.rawValue); set SEER_LOCAL_UTILITY=1 to enable."
        }
    }
}
