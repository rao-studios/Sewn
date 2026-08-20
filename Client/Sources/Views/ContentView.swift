import SwiftUI

struct ContentView: View {
    @StateObject private var appState = AppState()

    var body: some View {
        // Native macOS 26 sidebar (floating glass). Viable now that the
        // Workspace is two panes — earlier three-pane minimums plus the
        // resizable sidebar exceeded the window and shoved content off-screen.
        // Tint stays scoped per-control (segmented pickers, checkboxes), never
        // root-level: a global gold tint turns menu popups into gold-filled
        // buttons with illegible white text on macOS 26.
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
        } detail: {
            detail
                .background(Color.seerBG)
        }
        .navigationSplitViewStyle(.balanced)
        .environmentObject(appState)
        .preferredColorScheme(.light)  // palette is light-only; lock it
        .task { appState.autoSignIn() }
        .onChange(of: appState.servers.readyEpoch) {
            // A Seer just came up (or prod became reachable) — establish the
            // session so data screens load signed-in immediately.
            appState.autoSignIn()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                SeerMark(size: 24)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Seer")
                        .font(.seerSerif(20, weight: .light, italic: true))
                        .foregroundStyle(Color.seerInk)
                    Text("mission control")
                        .font(.seerSans(9, weight: .medium))
                        .foregroundStyle(Color.seerInk.opacity(0.4))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 18)

            ForEach(Screen.allCases) { screen in
                Button {
                    appState.screen = screen
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: screen.symbol)
                            .frame(width: 18)
                            .foregroundStyle(appState.screen == screen ? Color.seerGold : Color.seerInk.opacity(0.6))
                        Text(screen.rawValue)
                            .font(.seerSans(13, weight: appState.screen == screen ? .semibold : .regular))
                            .foregroundStyle(Color.seerInk)
                        Spacer()
                        sidebarBadge(for: screen)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(appState.screen == screen ? Color.seerGold.opacity(0.12) : .clear)
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
            }

            Spacer()

            Text("seer · totem · tinker")
                .font(.seerMono(8.5))
                .foregroundStyle(Color.seerInk.opacity(0.3))
                .padding(12)
        }
        // Translucent warm wash over the glass — blends without killing vibrancy.
        .background(Color.seerBG.opacity(0.45))
    }

    @ViewBuilder
    private func sidebarBadge(for screen: Screen) -> some View {
        if screen == .servers {
            switch appState.servers.environment {
            case .local:
                let running = (appState.servers.seerStatus == .running ? 1 : 0)
                    + appState.servers.totemStatus.values.filter { $0 == .running }.count
                if running > 0 {
                    SeerPill(text: "\(running)", tint: .seerGreen)
                }
            case .prod:
                SeerPill(text: "prod",
                         tint: appState.servers.prodSeerHealthy ? .seerGreen : .seerError)
            }
        }
    }

    /// All screens stay alive in a ZStack with only the active one visible —
    /// switching tabs never tears a screen down, so chat transcripts, search
    /// results, graph state, and Lab form state all persist across navigation.
    private var detail: some View {
        ZStack {
            screenPane(.servers) { ServersView() }
            screenPane(.workspace) { WorkspaceScreen() }
            screenPane(.lab) { LabView() }
            screenPane(.settings) { SettingsView() }
        }
    }

    private func screenPane<Content: View>(
        _ screen: Screen,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isActive = appState.screen == screen
        return content()
            .opacity(isActive ? 1 : 0)
            .zIndex(isActive ? 1 : 0)
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
    }
}
