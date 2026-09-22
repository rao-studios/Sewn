//
//  StackSecretMiddleware.swift
//  sewn-server
//
//  WHAT: Local mode. When the launcher gives this Sewn a stack secret — one
//        app's AMBIENT_STACK_SECRET, or on a shared ~/.rao stack every app's
//        secret from RAO_HOME — every request must carry one it knows in
//        X-Ambient-Secret and address this machine by loopback. On a shared
//        stack the secret that matched says which app is calling.
//  IN:   The StackMode decided once at start (RaoStack's `StackMode.sewn`)
//        from the launcher's environment. Hosted deployments and dev scripts
//        set nothing; the middleware isn't installed and nothing changes.
//  OUT:  401 without a secret this Sewn knows; 421 for a Host that isn't
//        loopback; otherwise `context.callerApp`, which every Thread fan-out
//        is scoped by (see `Sewn.nodeScope(for:)`).
//  PIN:  Keeps web pages out. A page can't send a custom header cross-site
//        without a CORS preflight, and local mode answers none; a
//        DNS-rebinding page arrives under its own Host and never learns a
//        secret. The caller's app is whichever secret matched — never a
//        header the client picked (X-Rao-App is read on /health alone).
//        /health stays open so a launcher can ask for proof of a secret
//        without sending it. The realtime WebSocket router never sees this
//        middleware and makes the same check through `admittedApp`.
//

import HTTPTypes
import Hummingbird
import RaoStack

extension HTTPField.Name {
    /// Every request's stack secret, except on /health.
    static let ambientSecret = HTTPField.Name(StackSecret.headerName)!
    /// /health's challenge. Never the secret.
    static let ambientNonce = HTTPField.Name(StackSecret.nonceHeaderName)!
    /// /health only: which app's secret the proof should use.
    static let raoApp = HTTPField.Name(StackSecret.appHeaderName)!
}

/// A request context that carries the app the stack secret named.
protocol StackCallerRequestContext: RequestContext {
    /// Set by StackSecretMiddleware: the app whose secret the request
    /// presented on a shared stack (or the one-app stack's own app, when its
    /// launcher named it); nil on an open server.
    var callerApp: RaoApp? { get set }
}

extension StackMode {
    /// The whole local-mode check for one request, in HTTP terms: the app it
    /// passes as, or the refusal to throw.
    func admittedApp(authority: String?, presented: String?) throws -> RaoApp? {
        switch admit(authority: authority, presented: presented) {
        case .admitted(let app):
            return app
        case .notLoopback:
            throw HTTPError(.misdirectedRequest, message: "This server answers on loopback only")
        case .badSecret:
            throw HTTPError(.unauthorized, message: "Missing or wrong X-Ambient-Secret")
        }
    }
}

struct StackSecretMiddleware<Context: StackCallerRequestContext>: RouterMiddleware {
    let mode: StackMode

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        if request.uri.path == "/health" {
            return try await next(request, context)
        }
        var context = context
        context.callerApp = try mode.admittedApp(
            authority: request.head.authority,
            presented: request.headers[.ambientSecret])
        return try await next(request, context)
    }
}
