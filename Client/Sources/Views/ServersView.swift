import SwiftUI

/// Server management. Local mode: one card for the Seer mothership, one per
/// Totem node, with a live log pane. Prod mode: read-only inspection of the
/// remote deployment (health + discovered fleet), no process control.
struct ServersView: View {
    @EnvironmentObject private var appState: AppState

    enum Selection: Hashable {
        case seer
        case totem(UUID)
    }

    @State private var selection: Selection = .seer
    /// Totem whose clear-DB confirmation dialog is showing.
    @State private var clearingTotemId: UUID?
    @State private var clearStatus: [UUID: String] = [:]

    private var servers: ServerController { appState.servers }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.seerBorder)

            if servers.environment == .local {
                localBody
            } else {
                prodBody
            }
        }
        .background(Color.seerBG)
        .confirmationDialog(
            "Clear this Totem's database?",
            isPresented: Binding(
                get: { clearingTotemId != nil },
                set: { if !$0 { clearingTotemId = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Clear database", role: .destructive) {
                if let id = clearingTotemId,
                   let config = servers.totemConfigs.first(where: { $0.id == id }) {
                    clearDatabase(config)
                }
                clearingTotemId = nil
            }
            Button("Cancel", role: .cancel) { clearingTotemId = nil }
        } message: {
            Text("Removes every document, graph entity, and registry entry from this node. This cannot be undone.")
        }
    }

    private func clearDatabase(_ config: TotemNodeConfig) {
        let api = TotemAPI(baseURL: servers.totemBaseURL(config))
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
                    servers.addTotem()
                } label: {
                    Label("Add Totem", systemImage: "plus")
                }
                .buttonStyle(.seerQuiet)
            } else {
                Button {
                    Task { await servers.refreshDiscoveredTotems() }
                } label: {
                    Label("Refresh fleet", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.seerQuiet)
            }
        }
    }

    // MARK: Local mode

    private var localBody: some View {
        HSplitView {
            ScrollView {
                VStack(spacing: 14) {
                    seerCard
                    ForEach(servers.totemConfigs) { config in
                        totemCard(config)
                    }
                }
                .padding(20)
            }
            .frame(minWidth: 430, idealWidth: 470, maxWidth: 560)

            logPane
                .frame(minWidth: 400)
        }
    }

    private var seerCard: some View {
        SeerCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    StatusDot(color: servers.seerStatus.color)
                    Text("Seer")
                        .font(.seerSerif(18, weight: .light, italic: true))
                        .foregroundStyle(Color.seerInk)
                        .fixedSize()
                    SeerPill(text: servers.seerStatus.label,
                             tint: servers.seerStatus == .running ? .seerGreen : .seerGold)
                    Spacer(minLength: 12)
                    controls(
                        isRunning: servers.seerStatus != .stopped,
                        start: { servers.startSeer(); selection = .seer },
                        stop: { Task { await servers.stopSeer() } },
                        restart: { Task { await servers.restartSeer() } }
                    )
                }

                HStack(spacing: 16) {
                    portField("http", value: Binding(
                        get: { servers.seerConfig.port },
                        set: { servers.seerConfig.port = $0 }))
                    portField("grpc", value: Binding(
                        get: { servers.seerConfig.grpcPort },
                        set: { servers.seerConfig.grpcPort = $0 }))
                    Spacer(minLength: 0)
                    Button("Logs") { selection = .seer }
                        .buttonStyle(.seerQuiet)
                }

                Text(servers.seerConfig.repoPath)
                    .font(.seerMono(9))
                    .foregroundStyle(Color.seerInk.opacity(0.35))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func totemCard(_ config: TotemNodeConfig) -> some View {
        let status = servers.totemStatus[config.id] ?? .stopped
        return SeerCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    StatusDot(color: status.color)
                    Text(config.label)
                        .font(.seerSerif(16, weight: .light, italic: true))
                        .foregroundStyle(Color.seerInk)
                        .fixedSize()
                    SeerPill(text: status.label,
                             tint: status == .running ? .seerGreen : .seerGold)
                    Spacer(minLength: 12)
                    controls(
                        isRunning: status != .stopped,
                        start: { servers.startTotem(config); selection = .totem(config.id) },
                        stop: { Task { await servers.stopTotem(config) } },
                        restart: {
                            Task {
                                await servers.stopTotem(config)
                                servers.startTotem(config)
                            }
                        }
                    )
                }

                HStack(spacing: 16) {
                    portField("http", value: bindingFor(config, \.port))
                    portField("grpc", value: bindingFor(config, \.grpcPort))
                    Spacer(minLength: 0)
                    Button("Logs") { selection = .totem(config.id) }
                        .buttonStyle(.seerQuiet)
                }

                HStack(spacing: 16) {
                    Toggle("MLX embeddings", isOn: bindingFor(config, \.useMLX))
                        .tint(Color.seerGold)
                    Toggle("LLM extraction", isOn: bindingFor(config, \.graphExtraction))
                        .tint(Color.seerGold)
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
                            .font(.seerSans(10))
                            .foregroundStyle(Color.seerInk.opacity(0.5))
                            .lineLimit(1)
                    }
                    Button {
                        clearingTotemId = config.id
                    } label: {
                        Image(systemName: "externaldrive.badge.xmark")
                    }
                    .buttonStyle(.seerIcon(tint: Color.seerError.opacity(0.7)))
                    .disabled(status != .running)
                    .help("Clear this node's database (documents, graph, registry)")
                    Button {
                        Task { await servers.removeTotem(config) }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.seerIcon(tint: Color.seerError.opacity(0.7)))
                    .help("Remove this node")
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(.seerSans(11))

                Text("node \(config.nodeId.uuidString.lowercased())")
                    .font(.seerMono(9))
                    .foregroundStyle(Color.seerInk.opacity(0.35))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func bindingFor<T>(_ config: TotemNodeConfig, _ keyPath: WritableKeyPath<TotemNodeConfig, T>) -> Binding<T> {
        Binding(
            get: {
                servers.totemConfigs.first { $0.id == config.id }?[keyPath: keyPath]
                    ?? config[keyPath: keyPath]
            },
            set: { newValue in
                guard let index = servers.totemConfigs.firstIndex(where: { $0.id == config.id }) else { return }
                servers.totemConfigs[index][keyPath: keyPath] = newValue
            }
        )
    }

    @ViewBuilder
    private func controls(isRunning: Bool, start: @escaping () -> Void,
                          stop: @escaping () -> Void, restart: @escaping () -> Void) -> some View {
        if isRunning {
            Button("Restart", action: restart).buttonStyle(.seerQuiet)
            Button("Stop", action: stop).buttonStyle(.seerQuiet)
        } else {
            Button("Start", action: start).buttonStyle(.seer)
        }
    }

    private func portField(_ label: String, value: Binding<Int>) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.seerMono(10))
                .foregroundStyle(Color.seerInk.opacity(0.45))
                .fixedSize()
            TextField("", value: value, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .font(.seerMono(11))
                .frame(width: 64)
        }
        .fixedSize()
    }

    @ViewBuilder
    private var logPane: some View {
        switch selection {
        case .seer:
            LogView(title: "seer-server", buffer: servers.seerLog)
        case .totem(let id):
            if let config = servers.totemConfigs.first(where: { $0.id == id }) {
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
                SeerCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            StatusDot(color: servers.prodSeerHealthy ? .seerGreen : .seerError)
                            Text("Seer — production")
                                .font(.seerSerif(18, weight: .light, italic: true))
                                .foregroundStyle(Color.seerInk)
                                .fixedSize()
                            SeerPill(text: servers.prodSeerHealthy ? "healthy" : "unreachable",
                                     tint: servers.prodSeerHealthy ? .seerGreen : .seerError)
                            Spacer(minLength: 12)
                        }
                        Text(servers.prodSeerURLString)
                            .font(.seerMono(10))
                            .foregroundStyle(Color.seerInk.opacity(0.5))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("Chat, Graph, Library, and Lab now target this deployment. Edit the URL and manual Totem endpoints in Settings.")
                            .font(.seerSans(11))
                            .foregroundStyle(Color.seerInk.opacity(0.45))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                SeerCard {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel("Fleet — \(servers.totemTargets.count) totem(s)")
                        if servers.totemTargets.isEmpty {
                            Text("No Totems discovered from /v1/totems and no manual endpoints configured (Settings → Production).")
                                .font(.seerSans(11))
                                .foregroundStyle(Color.seerInk.opacity(0.45))
                        }
                        ForEach(servers.totemTargets) { target in
                            HStack(spacing: 10) {
                                StatusDot(color: (servers.prodTotemHealthy[target.id] ?? false)
                                          ? .seerGreen : Color.seerInk.opacity(0.25))
                                Text(target.label)
                                    .font(.seerSans(12.5, weight: .medium))
                                    .foregroundStyle(Color.seerInk)
                                    .fixedSize()
                                if case .discovered = target.source {
                                    SeerPill(text: "discovered")
                                } else {
                                    SeerPill(text: "manual", tint: .seerGreen)
                                }
                                Spacer(minLength: 12)
                                Text(target.baseURL.absoluteString)
                                    .font(.seerMono(9.5))
                                    .foregroundStyle(Color.seerInk.opacity(0.45))
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
        .tint(Color.seerGold)
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
                    .buttonStyle(.seerQuiet)
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .frame(height: SeerMetrics.footerBarHeight)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(buffer.lines) { line in
                            Text(line.text)
                                .font(.seerMono(10.5))
                                .foregroundStyle(Color.seerInk.opacity(0.8))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(12)
                }
                .background(Color.seerFill)
                .onChange(of: buffer.lines.last?.id) { _, lastId in
                    if let lastId {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
        }
        .background(Color.seerBG)
    }
}
