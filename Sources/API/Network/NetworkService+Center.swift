import Foundation
import Hummingbird

extension NetworkService {
    enum BaseEndpoint : String, Codable {
        case mistral = "api.mistral.ai"
        case tinker = "tinker.thinkingmachines.dev"
        case airtable = "api.airtable.com"
        case supabase = "supabase.seer.services"

        /// The provider used for general LLM work (chat, utility one-shots).
        /// TTS and embeddings stay on `.mistral`. Overridable at boot via
        /// `SEER_GLOBAL_LLM=mistral|tinker` (set in `.env` or exported before
        /// starting the process) — defaults to `.mistral` when unset.
        static var globalLLM: BaseEndpoint {
            switch ProcessInfo.processInfo.environment["SEER_GLOBAL_LLM"]?.lowercased() {
            case "tinker": return .tinker
            case "mistral": return .mistral
            default: return .mistral
            }
        }

        var host: String { rawValue }

        /// Path prefix between the host and the API's own versioned paths.
        /// Tinker's Anthropic-compatible surface lives under a service prefix.
        var pathPrefix: String {
            switch self {
            case .tinker: return "/services/tinker-prod/anthropic/api"
            default:      return ""
            }
        }

        /// API keys come from the environment (`.env` is loaded into the process
        /// environment at boot by `loadDotEnv`). Missing keys fail loudly at call
        /// time with the variable name so misconfiguration is obvious.
        var apiKeyEnvVar: String {
            switch self {
            case .mistral:  return "MISTRAL_API_KEY"
            case .tinker:   return "TINKER_API_KEY"
            case .airtable: return "AIRTABLE_API_KEY"
            case .supabase: return "SUPABASE_SERVICE_KEY"
            }
        }

        var apiKey: String {
            if let key = ProcessInfo.processInfo.environment[apiKeyEnvVar], !key.isEmpty {
                return key
            }
            switch self {
            case .mistral, .tinker:
                // LLM keys are load-bearing — fail loudly with the variable name.
                fatalError("Missing \(apiKeyEnvVar) — add it to .env or export it before starting Seer.")
            case .airtable, .supabase:
                // Auxiliary services (log shipping, forms) degrade to unauthenticated
                // requests rather than taking the server down.
                return ""
            }
        }
    }

    struct Configuration: Codable {
        var base: BaseEndpoint
        var endpoint : String {
            "https://" + base.host + base.pathPrefix + "/"
        }
    }

    enum NetworkError: LocalizedError {
        case invalidRequestUrl
        case invalidResponse
        case unauthorized
        case backend(ErrorResponse)
        case noMockDataAvailable

        var errorDescription: String? { body }

        var body: String {
            switch self {
            case .invalidRequestUrl:
                return "Invalid request URL."
            case .invalidResponse:
                return "Invalid response data."
            case .unauthorized:
                return "Insufficient rights to perform the request."
            case .backend(let response):
                return response.message
            case .noMockDataAvailable:
                return "No mock data available."
            }
        }

        static func custom(_ message: String) -> NetworkError {
            // You may need to add a case to NetworkError enum
            .invalidRequestUrl // Placeholder - adjust based on your NetworkError definition
        }
    }
}
