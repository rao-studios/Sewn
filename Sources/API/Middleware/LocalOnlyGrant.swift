//
//  LocalOnlyGrant.swift
//  sewn-server
//
//  WHAT: The on-device lane with no account. A caller the stack secret
//        already named (StackSecretMiddleware: loopback, secret verified)
//        may reach a short list of routes with no bearer, acting as the
//        owner "local-<app>", and may run the `local` provider only.
//  IN:   AuthMiddleware (the grant); the chat and complete handlers (the
//        hosted refusal).
//  OUT:  `admits(method:endpointPath:)`, `ownerId(for:)`,
//        `provider(requested:isLocalOnly:app:)`.
//  PIN:  The list is exact endpoint patterns, never prefixes: a new route is
//        protected until someone adds it here. `local-` can never be a
//        Supabase id (those are UUIDs), so on-device data never lands in an
//        account's rows. A presented bearer is always validated; the grant
//        exists only for a request that sent none. Ambient mirrors
//        "local-ambient" in its own tests; change neither alone.
//

import HTTPTypes
import Hummingbird
import RaoStack

enum LocalOnlyGrant {
    struct Route: Hashable, Sendable {
        let method: HTTPRequest.Method
        /// Hummingbird's endpoint description: parameters render as `{name}`.
        let endpointPath: String
    }

    /// Every route a local caller may reach with no bearer. Nothing else.
    static let routes: Set<Route> = [
        Route(method: .post, endpointPath: "/v1/chat/completions"),
        Route(method: .post, endpointPath: "/v1/complete"),
        Route(method: .get, endpointPath: "/v1/providers"),
        Route(method: .post, endpointPath: "/v1/providers/local/warm"),
        Route(method: .get, endpointPath: "/v1/providers/local/sinatra/traces/{traceId}"),
        Route(method: .get, endpointPath: "/v1/providers/local/sinatra/analysis"),
    ]

    static func admits(method: HTTPRequest.Method, endpointPath: String?) -> Bool {
        guard let endpointPath else { return false }
        return routes.contains(Route(method: method, endpointPath: endpointPath))
    }

    /// The owner every local-only request acts as.
    static let ownerPrefix = "local-"

    static func ownerId(for app: RaoApp) -> String {
        ownerPrefix + app.rawValue
    }

    static func hostedRefusal(for app: RaoApp?) -> String {
        "Sign in to \(app?.displayName ?? "your app") to use hosted models."
    }

    /// The backend a request runs on. A local-only caller gets `.local` or a
    /// 401, including when it named nothing and the server default is hosted:
    /// a signed-out app is never routed to a hosted vendor by omission.
    static func provider(
        requested: LLMProvider?, isLocalOnly: Bool, app: RaoApp?
    ) throws -> LLMProvider {
        let provider = requested ?? .serverDefault
        guard !isLocalOnly || provider.isLocal else {
            throw HTTPError(.unauthorized, message: hostedRefusal(for: app))
        }
        return provider
    }
}

extension SewnRequestContext {
    /// `LocalOnlyGrant.provider` for this request. Call it before anything is dialled.
    func admittedProvider(_ requested: LLMProvider?) throws -> LLMProvider {
        try LocalOnlyGrant.provider(requested: requested, isLocalOnly: isLocalOnly, app: callerApp)
    }
}
