import SwiftUI

/// The unified investigation surface: a switchable context pane (Library ⇄
/// Graph, segmented control in the header) beside Chat. Each pane keeps its
/// own thread target picker; the workspace wires them together:
///  - Chat source-chip tap → switches the context pane to Graph and highlights
///    that document's entities.
///  - Library search → primes the graph trace overlay from the same
///    `/v1/search` response when both panes target the same thread, so
///    switching to Graph shows the trace with no extra request.
struct WorkspaceScreen: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var chatViewModel = ChatViewModel()
    @StateObject private var graphViewModel = GraphViewModel()

    private enum ContextTab: String {
        case library
        case graph
    }

    @AppStorage("sewn.client.workspace.contextTab") private var contextTabRaw = ContextTab.library.rawValue
    private var contextTab: ContextTab { ContextTab(rawValue: contextTabRaw) ?? .library }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Workspace") {
                Picker("", selection: $contextTabRaw) {
                    Text("Library").tag(ContextTab.library.rawValue)
                    Text("Graph").tag(ContextTab.graph.rawValue)
                }
                .pickerStyle(.segmented)
                .tint(Color.sewnGold)
                .frame(width: 180)
            } trailing: {
                if appState.servers.environment == .prod {
                    SewnPill(text: "prod", tint: .sewnError)
                }
            }
            Divider().overlay(Color.sewnBorder)
            // Two panes: minimums (340 + 380) leave ample slack beside the
            // native sidebar at any window width ≥ the 1200 minimum.
            HSplitView {
                Group {
                    switch contextTab {
                    case .library:
                        LibraryPane(onSearchResult: handleLibrarySearch)
                    case .graph:
                        GraphPane(viewModel: graphViewModel)
                    }
                }
                .frame(minWidth: 340, idealWidth: 440, maxWidth: 640)
                ChatPane(viewModel: chatViewModel, onReferenceTap: handleReferenceTap)
                    .frame(minWidth: 380)
            }
        }
        .background(Color.sewnBG)
    }

    // MARK: - Cross-pane wiring

    private func handleReferenceTap(_ reference: ChatReference) {
        withAnimation { contextTabRaw = ContextTab.graph.rawValue }
        Task { await graphViewModel.highlightDocument(id: reference.id) }
    }

    private func handleLibrarySearch(query: String, targetId: String, response: SearchResponseBody) {
        // The graph pane is hidden while the library is showing — prime its
        // trace overlay only when the response already carries the data
        // (same thread target); never spend a network call on a hidden pane.
        if graphViewModel.target?.id == targetId {
            graphViewModel.applyTrace(query: query, response: response)
        }
    }
}
