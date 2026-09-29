//
//  VendorEgress.swift
//  sewn-server
//
//  WHAT: A refusal, scoped to one task tree, to call a hosted LLM vendor.
//  IN:   Sewn.handleChat raises it for an on-device turn.
//  OUT:  NetworkService.request and ModelProvider's SSE driver throw
//        ProviderUnavailable.egressRefused before anything is dialled.
//  PIN:  Task-local, so the passes a turn spawns (Sinatra, auto-memory, recap)
//        inherit it. Only LLM vendors are held back: Supabase is Rao's own
//        account service. A pass that forgets to pass the turn's provider
//        fails closed here instead of sending the user's words away.
//

import Foundation

enum VendorEgress {
    /// Why this task may not reach a vendor, or nil when it may.
    @TaskLocal static var refusal: String?

    /// Runs `body` with vendor calls refused when `refused` is true.
    static func refusing<T>(when refused: Bool, _ body: () async throws -> T) async rethrows -> T {
        guard refused else { return try await body() }
        return try await $refusal.withValue("on-device turn", operation: body)
    }

    /// Throws when this task may not call `base`.
    static func check(_ base: NetworkService.BaseEndpoint) throws {
        guard let refusal, isVendor(base) else { return }
        throw ProviderUnavailable.egressRefused(host: base.host, reason: refusal)
    }

    /// Throws when this task may not call `url`'s host.
    static func check(_ url: URL?) throws {
        guard let refusal, let host = url?.host,
              let base = NetworkService.BaseEndpoint(rawValue: host), isVendor(base) else { return }
        throw ProviderUnavailable.egressRefused(host: host, reason: refusal)
    }

    private static func isVendor(_ base: NetworkService.BaseEndpoint) -> Bool {
        switch base {
        case .mistral, .tinker: return true
        case .supabase: return false
        }
    }
}
