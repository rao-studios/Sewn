import Combine
import Foundation
import SwiftUI

/// The screens in the workflow sidebar.
enum Screen: String, CaseIterable, Identifiable {
    case servers = "Servers"
    case workspace = "Workspace"
    case lab = "Lab"
    case settings = "Settings"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .servers: return "server.rack"
        case .workspace: return "rectangle.split.3x1"
        case .lab: return "flask"
        case .settings: return "gearshape"
        }
    }
}

/// Development sign-in used for auto-login on launch, read from the launch
/// environment (SEWN_DEV_EMAIL, SEWN_DEV_PASSWORD) — never from source. Unset,
/// there is no auto-login: sign in through Settings → Account.
enum DevCredentials {
    static var current: (email: String, password: String)? {
        let environment = ProcessInfo.processInfo.environment
        guard let email = environment["SEWN_DEV_EMAIL"], !email.isEmpty,
              let password = environment["SEWN_DEV_PASSWORD"], !password.isEmpty
        else { return nil }
        return (email, password)
    }
}

/// App-wide state container (single source of truth, injected via environment).
@MainActor
final class AppState: ObservableObject {

    // Navigation
    @Published var screen: Screen = .servers

    /// Bumped when a sign-in completes so data screens re-fetch auth'd state.
    @Published var sessionEpoch = 0

    // Server process supervision
    let servers = ServerController()

    // API clients (Phase 3 wires these to auth + chat)
    lazy var sewnAPI = SewnAPI(baseURL: { [servers] in servers.sewnBaseURLSnapshot })

    private var cancellables = Set<AnyCancellable>()
    private var autoSignInTask: Task<Void, Never>?

    init() {
        // Seed the base-URL snapshot with the restored config.
        servers.sewnConfig = servers.sewnConfig

        // ServerController is a nested ObservableObject — its @Published
        // changes (server status, environment, discovered threads) don't fire
        // this object's objectWillChange on their own, which left views stale
        // until a tab switch re-evaluated them. Forward the publisher.
        servers.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// Signs in with the environment's dev credentials when no session exists.
    /// Safe to call repeatedly — retried whenever a Sewn becomes reachable
    /// (readyEpoch). No credentials in the environment, no auto-login.
    func autoSignIn() {
        guard autoSignInTask == nil, let credentials = DevCredentials.current else { return }
        autoSignInTask = Task { [weak self] in
            defer { self?.autoSignInTask = nil }
            guard let self, await !self.sewnAPI.isSignedIn else { return }
            do {
                try await self.sewnAPI.signIn(email: credentials.email,
                                              password: credentials.password)
                self.sessionEpoch += 1
            } catch {
                // Sewn not up yet or auth unavailable — retried on next readyEpoch.
            }
        }
    }
}
