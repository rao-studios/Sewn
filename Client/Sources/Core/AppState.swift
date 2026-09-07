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

/// Development sign-in used for auto-login on launch. The account is a shared
/// test identity — replace via Settings → Account for a personal session.
enum TestCredentials {
    static let email = "admin@seer.social"
    static let password = "cogqab-jazhEv-5rudhi"
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

    /// Signs in with the test credentials when no session exists. Safe to call
    /// repeatedly — retried whenever a Sewn becomes reachable (readyEpoch).
    func autoSignIn() {
        guard autoSignInTask == nil else { return }
        autoSignInTask = Task { [weak self] in
            defer { self?.autoSignInTask = nil }
            guard let self, await !self.sewnAPI.isSignedIn else { return }
            do {
                try await self.sewnAPI.signIn(email: TestCredentials.email,
                                              password: TestCredentials.password)
                self.sessionEpoch += 1
            } catch {
                // Sewn not up yet or auth unavailable — retried on next readyEpoch.
            }
        }
    }
}
