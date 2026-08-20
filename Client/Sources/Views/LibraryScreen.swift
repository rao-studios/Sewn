import SwiftUI
import UniformTypeIdentifiers

/// Library pane: ingest files into a Totem node and search its corpus directly.
/// Lives as the left pane of the Workspace; keeps its own totem target picker.
struct LibraryPane: View {
    @EnvironmentObject private var appState: AppState
    /// Fired after a successful search so the workspace can drive the graph trace
    /// from the same `/v1/search` response (no second network call).
    var onSearchResult: ((_ query: String, _ targetId: String, _ response: SearchResponseBody) -> Void)?

    @State private var selectedTargetId: String?
    @State private var searchQuery = ""
    @State private var results: [String] = []
    @State private var status: String?
    @State private var isWorking = false
    @State private var groupId = "library"

    private var selectedTarget: TotemTarget? {
        let targets = appState.servers.totemTargets
        return targets.first { $0.id == selectedTargetId } ?? targets.first
    }

    private var ownerId: String {
        KeychainStore.get("user_id") ?? "client-local"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.seerBorder)

            if selectedTarget == nil {
                EmptyHero(title: "Library",
                          subtitle: appState.servers.environment == .local
                              ? "Add a Totem node on the Servers screen first."
                              : "No prod Totems reachable — check the Servers screen or add a manual endpoint in Settings.")
            } else {
                content
            }

            statusBar
        }
        .background(Color.seerBG)
    }

    private var header: some View {
        PaneHeader {
            HStack(spacing: 8) {
                SectionLabel("Library")
                Picker("", selection: $selectedTargetId) {
                    ForEach(appState.servers.totemTargets) { target in
                        Text(target.label).tag(String?.some(target.id))
                    }
                }
                .frame(minWidth: 90, maxWidth: 150)
                Spacer(minLength: 8)
            }
            HStack(spacing: 8) {
                TextField("group id", text: $groupId)
                    .textFieldStyle(.roundedBorder)
                    .font(.seerMono(11))
                    .frame(width: 110)
                Button {
                    ingestFiles()
                } label: {
                    Label("Ingest…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.seer)
                .disabled(isWorking)
                Spacer(minLength: 8)
            }
        }
    }

    /// Fixed-height footer: ingest/search status lives here so the header —
    /// and the divider it shares with the other panes — never shifts.
    private var statusBar: some View {
        PaneFooter {
            Text(status ?? "\(results.count) result(s)")
                .font(.seerSans(11))
                .foregroundStyle(Color.seerInk.opacity(status == nil ? 0.35 : 0.55))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var content: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                TextField("search this node…", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { runSearch() }
                Button("Search") { runSearch() }
                    .buttonStyle(.seerQuiet)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            if results.isEmpty {
                EmptyHero(title: "Search the corpus",
                          subtitle: "Results show the retrieved partition texts from the selected Totem node.")
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(Array(results.enumerated()), id: \.offset) { _, text in
                            SeerCard(padding: 14) {
                                Text(text)
                                    .font(.seerSans(12.5))
                                    .foregroundStyle(Color.seerInk)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    private func runSearch() {
        guard let target = selectedTarget, !searchQuery.isEmpty else { return }
        let api = TotemAPI(baseURL: target.baseURL)
        let owner = ownerId
        let query = searchQuery
        Task {
            do {
                let response = try await api.search(ownerId: owner, query: query)
                results = response.texts ?? []
                status = "\(results.count) result(s)"
                onSearchResult?(query, target.id, response)
            } catch {
                status = error.localizedDescription
            }
        }
    }

    /// Ingest goes through Seer (`/v1/embeddings`), which relays to the selected
    /// totem over its Conduit gRPC session — the production path. The Totem's
    /// direct REST route stays available for standalone (Seer-less) nodes.
    private func ingestFiles() {
        guard let target = selectedTarget else { return }
        let urls = FilePicker.pickFiles().filter { !$0.hasDirectoryPath }
        guard !urls.isEmpty else { return }
        let api = appState.seerAPI
        let group = groupId
        let totemNodeId = target.nodeId
        isWorking = true
        status = "ingesting \(urls.count) file(s) via Seer → \(target.label)…"
        Task {
            var ingested = 0
            for url in urls {
                guard let text = DocumentText.extract(from: url) else {
                    status = "\(url.lastPathComponent): no extractable text — skipped"
                    continue
                }
                do {
                    if try await api.ingest(texts: [text],
                                            names: [url.lastPathComponent],
                                            groupId: group,
                                            personalTotemId: totemNodeId) {
                        ingested += 1
                    }
                } catch {
                    status = "\(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
            status = "ingested \(ingested)/\(urls.count) via Seer → Conduit — extraction continues in the background"
            isWorking = false
        }
    }
}
