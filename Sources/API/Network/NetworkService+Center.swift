//
//  NetworkService+Center.swift
//  sewn-server
//
//  WHAT: The hosts Sewn calls out to and where each one's key comes from.
//  IN:   Provider keys: RAO_HOME/keys/providers.json through RaoStack's
//        ProviderKeyStore when a launcher set RAO_HOME (a key typed into any
//        Rao app reaches this Sewn on its next call), else the process
//        environment (a dev checkout's .env, a hosted deployment's secrets).
//        Supabase: the environment only — the anon key is public
//        configuration, not a user's key, and sewn.env may carry it.
//  OUT:  `requireAPIKey()` for LLM hosts (a 503 when missing), `apiKey` for
//        auxiliary services that degrade to unauthenticated requests.
//  PIN:  Missing keys fail at call time, named, so misconfiguration is
//        obvious; nothing here crashes the server.
//

import Foundation
import Hummingbird
import RaoStack

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

        /// The key's name: in the shared provider file and in the environment
        /// (`.env` is loaded into the process environment at boot). Missing
        /// keys fail loudly at call time with this name.
        var apiKeyEnvVar: String {
            switch self {
            case .mistral:  return ProviderKeyStore.mistralAPIKey
            case .tinker:   return ProviderKeyStore.tinkerAPIKey
            // Supabase is reached as the anon role, never the service role:
            // Sewn holds no key that bypasses row-level security.
            case .supabase: return "SUPABASE_ANON_KEY"
            }
        }

        /// The key when one is set. Nil is an answer here, not a crash: a
        /// client may select a provider whose key was never set.
        var apiKeyIfPresent: String? {
            switch self {
            case .mistral, .tinker:
                // Shared file first (when RAO_HOME is set), then the environment.
                return ProviderKeyStore.process.value(for: apiKeyEnvVar)
            case .supabase:
                guard let key = ProcessInfo.processInfo.environment[apiKeyEnvVar], !key.isEmpty
                else { return nil }
                return key
            }
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
