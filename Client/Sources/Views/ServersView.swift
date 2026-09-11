import SwiftUI

/// Server management. Local mode: one card for the Sewn mothership, one per
/// Thread node, with a live log pane. Prod mode: read-only inspection of the
/// remote deployment (health + discovered fleet), no process control.
struct ServersView: View {
    @EnvironmentObject private var appState: AppState

    enum Selection: Hashable {
        case sewn
        case thread(UUID)
    }

    @State private var selection: Selection = .sewn
    /// Thread whose clear-DB confirmation dialog is showing.
    @State private var clearingThreadId: UUID?
    @State private var clearStatus: [UUID: String] = [:]

    private var servers: ServerController { appState.servers }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.sewnBorder)

            if servers.environment == .local {
                localBody
            } else {
                prodBody
            }
        }
        .background(Color.sewnBG)
        .confirmationDialog(
            "Clear this Thread's database?",
            isPresented: Binding(
                get: { clearingThreadId != nil },
                set: { if !$0 { clearingThreadId = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Clear database", role: .destructive) {
                if let id = clearingThreadId,
                   let config = servers.threadConfigs.first(where: { $0.id == id }) {
                    clearDatabase(config)
                }
                clearingThreadId = nil
            }
            Button("Cancel", role: .cancel) { clearingThreadId = nil }
        } message: {
            Text("Removes every document, graph entity, and registry entry from this node. This cannot be undone.")
        }
    }

    private func clearDatabase(_ config: ThreadNodeConfig) {
        let api = ThreadAPI(baseURL: servers.threadBaseURL(config))
        clearStatus[config.id] = "clearing…"
        Task {
            do {
                let result = try await api.clearDatabase()
                clearStatus[config.id] = "cleared \(result.documents) doc(s), \(result.entities) entity(ies)"
            } catch {
                clearStatus[config.id] = error.localizedDescription
            }
        }
    }

    // MARK: Header

    private var header: some View {
        ScreenHeader(title: "Servers") {
            EnvironmentToggle()
        } trailing: {
            if servers.environment == .local {
                Button {
                    servers.addThread()
                } label: {
                    Label("Add Thread", systemImage: "plus")
                }
                .buttonStyle(.sewnQuiet)
            } else {
                Button {
                    Task { await servers.refreshDiscoveredThreads() }
                } label: {
                    Label("Refresh fleet", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.sewnQuiet)
            }
        }
    }

    // MARK: Local mode

    private var localBody: some View {
        HSplitView {
            ScrollView {
                VStack(spacing: 14) {
                    sewnCard
                    ForEach(servers.threadConfigs) { config in
                        threadCard(config)
                    }
                }
                .padding(20)
            }
            .frame(minWidth: 430, idealWidth: 470, maxWidth: 560)

            logPane
                .frame(minWidth: 400)
        }
    }

    private var sewnCard: some View {
        SewnCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    StatusDot(color: servers.sewnStatus.color)
                    Text("Sewn")
                        .font(.sewnSerif(18, weight: .light, italic: true))
                        .foregroundStyle(Color.sewnInk)
                        .fixedSize()
                    SewnPill(text: servers.sewnStatus.label,
                             tint: servers.sewnStatus == .running ? .sewnGreen : .sewnGold)
                    Spacer(minLength: 12)
                    controls(
                        isRunning: servers.sewnStatus != .stopped,
                        start: { servers.startSewn(); selection = .sewn },
                        stop: { Task { await servers.stopSewn() } },
                        restart: { Task { await servers.restartSewn() } }
                    )
                }

                HStack(spacing: 16) {
                    portField("http", value: Binding(
                        get: { servers.sewnConfig.port },
                        set: { servers.sewnConfig.port = $0 }))
                    portField("grpc", value: Binding(
                        get: { servers.sewnConfig.grpcPort },
                        set: { servers.sewnConfig.grpcPort = $0 }))
                    Spacer(minLength: 0)
                    Button("Logs") { selection = .sewn }
                        .buttonStyle(.sewnQuiet)
                }

                Text(servers.sewnConfig.repoPath)
                    .font(.sewnMono(9))
                    .foregroundStyle(Color.sewnInk.opacity(0.35))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func threadCard(_ config: ThreadNodeConfig) -> some View {
        let status = servers.threadStatus[config.id] ?? .stopped
        return SewnCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    StatusDot(color: status.color)
                    Text(config.label)
                        .font(.sewnSerif(16, weight: .light, italic: true))
                        .foregroundStyle(Color.sewnInk)
                        .fixedSize()
                    SewnPill(text: status.label,
                             tint: status == .running ? .sewnGreen : .sewnGold)
                    Spacer(minLength: 12)
                    controls(
                        isRunning: status != .stopped,
                        start: { servers.startThread(config); selection = .thread(config.id) },
                        stop: { Task { await servers.stopThread(config) } },
                        restart: {
                            Task {
                                await servers.stopThread(config)
                                servers.startThread(config)
                            }
                        }
                    )
                }

                HStack(spacing: 16) {
                    portField("http", value: bindingFor(config, \.port))
                    portField("grpc", value: bindingFor(config, \.grpcPort))
                    Spacer(minLength: 0)
                    Button("Logs") { selection = .thread(config.id) }
                        .buttonStyle(.sewnQuiet)
                }

                HStack(spacing: 16) {
                    Toggle("MLX embeddings", isOn: bindingFor(config, \.useMLX))
                        .tint(Color.sewnGold)
                    Toggle("LLM extraction", isOn: bindingFor(config, \.graphExtraction))
                        .tint(Color.sewnGold)
                    Picker("", selection: bindingFor(config, \.graphBackend)) {
                        Text("MLX").tag("mlx")
                        Text("Mistral").tag("mistral")
                    }
                    .frame(width: 90)
                    .fixedSize()
                    .disabled(!config.graphExtraction)
                    .help("Extraction backend: on-device MLX or the Mistral API")
                    Spacer(minLength: 0)
                    if let status = clearStatus[config.id] {
                        Text(status)
                            .font(.sewnSans(10))
                            .foregroundStyle(Color.sewnInk.opacity(0.5))
                            .lineLimit(1)
                    }
                    Button {
                        clearingThreadId = config.id
                    } label: {
                        Image(systemName: "externaldrive.badge.xmark")
                    }
                    .buttonStyle(.sewnIcon(tint: Color.sewnError.opacity(0.7)))
                    .disabled(status != .running)
                    .help("Clear this node's database (documents, graph, registry)")
                    Button {
                        Task { await servers.removeThread(config) }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.sewnIcon(tint: Color.sewnError.opacity(0.7)))
                    .help("Remove this node")
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(.sewnSans(11))

                Text("node \(config.nodeId.uuidString.lowercased())")
                    .font(.sewnMono(9))
                    .foregroundStyle(Color.sewnInk.opacity(0.35))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func bindingFor<T>(_ config: ThreadNodeConfig, _ keyPath: WritableKeyPath<ThreadNodeConfig, T>) -> Binding<T> {
        Binding(
            get: {
                servers.threadConfigs.first { $0.id == config.id }?[keyPath: keyPath]
                    ?? config[keyPath: keyPath]
            },
            set: { newValue in
                guard let index = servers.threadConfigs.firstIndex(where: { $0.id == config.id }) else { return }
                servers.threadConfigs[index][keyPath: keyPath] = newValue
            }
        )
    }

    @ViewBuilder
    private func controls(isRunning: Bool, start: @escaping () -> Void,
                          stop: @escaping () -> Void, restart: @escaping () -> Void) -> some View {
        if isRunning {
            Button("Restart", action: restart).buttonStyle(.sewnQuiet)
            Button("Stop", action: stop).buttonStyle(.sewnQuiet)
        } else {
            Button("Start", action: start).buttonStyle(.sewn)
        }
    }

    private func portField(_ label: String, value: Binding<Int>) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.sewnMono(10))
                .foregroundStyle(Color.sewnInk.opacity(0.45))
                .fixedSize()
            TextField("", value: value, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .font(.sewnMono(11))
                .frame(width: 64)
        }
        .fixedSize()
    }

    @ViewBuilder
    private var logPane: some View {
        switch selection {
        case .sewn:
            LogView(title: "sewn-server", buffer: servers.sewnLog)
        case .thread(let id):
            if let config = servers.threadConfigs.first(where: { $0.id == id }) {
                LogView(title: config.label, buffer: servers.log(for: id))
            } else {
                EmptyHero(title: "No node selected",
                          subtitle: "Select a server card to stream its logs.")
            }
        }
    }

    // MARK: Prod mode (read-only inspection)

    private var prodBody: some View {
        ScrollView {
            VStack(spacing: 14) {
                SewnCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            StatusDot(color: servers.prodSewnHealthy ? .sewnGreen : .sewnError)
                            Text("Sewn — production")
                                .font(.sewnSerif(18, weight: .light, italic: true))
                                .foregroundStyle(Color.sewnInk)
                                .fixedSize()
                            SewnPill(text: servers.prodSewnHealthy ? "healthy" : "unreachable",
                                     tint: servers.prodSewnHealthy ? .sewnGreen : .sewnError)
                            Spacer(minLength: 12)
                        }
                        Text(servers.prodSewnURLString)
                            .font(.sewnMono(10))
                            .foregroundStyle(Color.sewnInk.opacity(0.5))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("Chat, Graph, Library, and Lab now target this deployment. Edit the URL and manual Thread endpoints in Settings.")
                            .font(.sewnSans(11))
                            .foregroundStyle(Color.sewnInk.opacity(0.45))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                SewnCard {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel("Fleet — \(servers.threadTargets.count) thread(s)")
                        if servers.threadTargets.isEmpty {
                            Text("No Threads discovered from /v1/threads and no manual endpoints configured (Settings → Production).")
                                .font(.sewnSans(11))
                                .foregroundStyle(Color.sewnInk.opacity(0.45))
                        }
                        ForEach(servers.threadTargets) { target in
                            HStack(spacing: 10) {
                                StatusDot(color: (servers.prodThreadHealthy[target.id] ?? false)
                                          ? .sewnGreen : Color.sewnInk.opacity(0.25))
                                Text(target.label)
                                    .font(.sewnSans(12.5, weight: .medium))
                                    .foregroundStyle(Color.sewnInk)
                                    .fixedSize()
                                if case .discovered = target.source {
                                    SewnPill(text: "discovered")
                                } else {
                                    SewnPill(text: "manual", tint: .sewnGreen)
                                }
                                Spacer(minLength: 12)
                                Text(target.baseURL.absoluteString)
                                    .font(.sewnMono(9.5))
                                    .foregroundStyle(Color.sewnInk.opacity(0.45))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
            .frame(maxWidth: 760)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Local/Prod segmented switch — shared by Servers header and Settings.
struct EnvironmentToggle: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Picker("", selection: Binding(
            get: { appState.servers.environment },
            set: { appState.servers.environment = $0 }
        )) {
            ForEach(AppEnvironment.allCases) { environment in
                Text(environment.rawValue).tag(environment)
            }
        }
        .pickerStyle(.segmented)
        .tint(Color.sewnGold)
        .frame(width: 150)
        .help("Switch between locally managed servers and the production deployment")
    }
}

/// Auto-scrolling monospaced log tail bound to a LogBuffer.
struct LogView: View {
    let title: String
    @ObservedObject var buffer: LogBuffer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel("\(title) — log")
                Spacer()
                Button("Clear") { buffer.clear() }
                    .buttonStyle(.sewnQuiet)
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .frame(height: SewnMetrics.footerBarHeight)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(buffer.lines) { line in
                            Text(line.text)
                                .font(.sewnMono(10.5))
                                .foregroundStyle(Color.sewnInk.opacity(0.8))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(12)
                }
                .background(Color.sewnFill)
                .onChange(of: buffer.lines.last?.id) { _, lastId in
                    if let lastId {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
        }
        .background(Color.sewnBG)
    }
}
