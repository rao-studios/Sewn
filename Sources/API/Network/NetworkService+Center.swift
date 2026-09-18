import Foundation
import Hummingbird

extension NetworkService {
    enum BaseEndpoint : String, Codable {
        case mistral = "api.mistral.ai"
        case tinker = "tinker.thinkingmachines.dev"
        case supabase = "supabase.seer.services"

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
            case .supabase: return "SUPABASE_SERVICE_KEY"
            }
        }

        /// The key when the environment has one. Nil is an answer here, not
        /// a crash: a client may select a provider whose key was never set.
        var apiKeyIfPresent: String? {
            guard let key = ProcessInfo.processInfo.environment[apiKeyEnvVar], !key.isEmpty
            else { return nil }
            return key
        }

        /// LLM hosts need their key; a missing one is a 503 to the client,
        /// never a fatalError.
        func requireAPIKey() throws -> String {
            guard let key = apiKeyIfPresent else {
                throw ProviderUnavailable.missingKey(envVar: apiKeyEnvVar)
            }
            return key
        }

        /// Auxiliary services (log shipping, forms) degrade to unauthenticated
        /// requests rather than taking the server down.
        var apiKey: String {
            apiKeyIfPresent ?? ""
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
