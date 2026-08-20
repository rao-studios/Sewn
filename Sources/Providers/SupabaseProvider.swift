//
//  SupabaseProvider.swift
//  seer-server
//
//  Created by Ritesh Pakala Rao on 2/22/26.
//

import Foundation
import Supabase
import Hummingbird

/// Thread-safe in-memory implementation of ``AuthLocalStorage``.
/// Used on Linux (and any platform without Keychain/WinCred) where no
/// platform-provided credential store is available.
final class InMemoryLocalStorage: AuthLocalStorage, @unchecked Sendable {
    private var store: [String: Data] = [:]
    private let lock = NSLock()

    func store(key: String, value: Data) throws {
        lock.withLock { store[key] = value }
    }

    func retrieve(key: String) throws -> Data? {
        lock.withLock { store[key] }
    }

    func remove(key: String) throws {
        lock.withLock { _ = store.removeValue(forKey: key) }
    }
}

/// Shared Supabase client for stateless auth operations (sign-up, sign-in,
/// verify, refresh, reset-password). All of these pass tokens explicitly and
/// do not depend on stored session state, so a single instance is safe for
/// concurrent requests.
///
/// For sign-out — which requires an active session to be set on the client —
/// use `SupabaseProvider.makeClient()` to obtain a per-request instance.
enum SupabaseProvider {
    static let shared: SupabaseClient = {
        guard
            let urlString = ProcessInfo.processInfo.environment["SUPABASE_URL"],
            let url = URL(string: urlString),
            let key = ProcessInfo.processInfo.environment["SUPABASE_ANON_KEY"]
        else {
            fatalError("SUPABASE_URL or SUPABASE_ANON_KEY environment variables are not set")
        }
        return SupabaseClient(
            supabaseURL: url,
            supabaseKey: key,
            options: SupabaseClientOptions(
                auth: .init(storage: InMemoryLocalStorage())
            )
        )
    }()

    /// Creates a fresh client for operations that require setting session state
    /// (e.g. sign-out). Throws if environment variables are missing.
    static func makeClient() throws -> SupabaseClient {
        guard
            let urlString = ProcessInfo.processInfo.environment["SUPABASE_URL"],
            let url = URL(string: urlString),
            let key = ProcessInfo.processInfo.environment["SUPABASE_ANON_KEY"]
        else {
            throw HTTPError(.internalServerError, message: "Auth service not configured")
        }
        return SupabaseClient(
            supabaseURL: url,
            supabaseKey: key,
            options: SupabaseClientOptions(
                auth: .init(storage: InMemoryLocalStorage())
            )
        )
    }
}
