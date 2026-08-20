import Foundation
import SwiftUI

/// Lock-protected box so nonisolated callers (API client closures) can read
/// values owned by the MainActor controller.
final class LockBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T

    init(_ value: T) { self.stored = value }

    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

// MARK: - Configs

struct SeerServerConfig: Codable, Equatable {
    static let legacyRepoPath = NSString(
        string: "~/Documents/projects/seer/Seer").expandingTildeInPath
    static let defaultRepoPath = NSString(
        string: "~/Documents/rao/repositories/Seer").expandingTildeInPath

    var repoPath: String = defaultRepoPath
    var host: String = "127.0.0.1"
    var port: Int = 8080
    var grpcPort: Int = 9091

    static func migratedRepoPath(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath == legacyRepoPath
            ? defaultRepoPath
            : path
    }
}

struct TotemNodeConfig: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var repoPath: String = NSString(string: "~/Documents/rao/repositories/Totem").expandingTildeInPath
    var host: String = "127.0.0.1"
    var port: Int = 8081
    var grpcPort: Int = 9090
    /// Persisted node UUID passed as `--node-id` so restarts keep identity.
    var nodeId: UUID = UUID()
    var useMLX: Bool = false
    var graphExtraction: Bool = true
    /// Extraction backend passed as `--graph-backend`: "mlx" (on-device) or "mistral" (API).
    var graphBackend: String = "mlx"
    var graphModel: String = "mlx-community/Qwen3-1.7B-4bit"

    var label: String { "totem-\(String(nodeId.uuidString.prefix(8)).lowercased())" }

    init() {}

    /// Tolerant decoding: every field falls back to its default when absent so
    /// configs persisted by older builds (no `graphBackend` key) keep decoding —
    /// a hard failure here would silently reset node identities.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = TotemNodeConfig()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? defaults.id
        repoPath = try c.decodeIfPresent(String.self, forKey: .repoPath) ?? defaults.repoPath
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? defaults.host
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? defaults.port
        grpcPort = try c.decodeIfPresent(Int.self, forKey: .grpcPort) ?? defaults.grpcPort
        nodeId = try c.decodeIfPresent(UUID.self, forKey: .nodeId) ?? defaults.nodeId
        useMLX = try c.decodeIfPresent(Bool.self, forKey: .useMLX) ?? defaults.useMLX
        graphExtraction = try c.decodeIfPresent(Bool.self, forKey: .graphExtraction) ?? defaults.graphExtraction
        graphBackend = try c.decodeIfPresent(String.self, forKey: .graphBackend) ?? defaults.graphBackend
        graphModel = try c.decodeIfPresent(String.self, forKey: .graphModel) ?? defaults.graphModel
    }
}

/// Which deployment the app inspects: locally managed processes, or a remote
/// production deployment reached over customizable URLs.
enum AppEnvironment: String, Codable, CaseIterable, Identifiable {
    case local = "Local"
    case prod = "Prod"
    var id: String { rawValue }
}

/// A manually configured remote Totem endpoint (prod mode).
struct ProdTotemConfig: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String = "prod-totem"
    var urlString: String = "http://"
}

/// A Totem the Graph/Library screens can target, regardless of environment.
struct TotemTarget: Identifiable, Equatable {
    enum Source: Equatable { case local(UUID), discovered, manual(UUID) }
    let id: String
    let label: String
    let baseURL: URL
    let source: Source
    /// The totem's node UUID as registered with Seer — what the `seer` request
    /// block's `personal_totem_id`/`totem_ids` expect. Nil for manual endpoints
    /// whose node identity is unknown (Seer then picks a storage totem itself).
    var nodeId: String? = nil
}

enum ServerStatus: Equatable {
    case stopped
    case building     // swift run compiling, health not yet answering
    case running
    case unhealthy    // process alive but health check failing after it was up

    var color: Color {
        switch self {
        case .stopped:   return Color.seerInk.opacity(0.25)
        case .building:  return Color.seerGold
        case .running:   return Color.seerGreen
        case .unhealthy: return Color.seerError
        }
    }

    var label: String {
        switch self {
        case .stopped: return "stopped"
        case .building: return "starting"
        case .running: return "running"
        case .unhealthy: return "unhealthy"
        }
    }
}

// MARK: - Controller

/// Owns every managed server process: one Seer, N Totems. Persists configs,
/// launches `swift run` in the configured repo checkouts, polls health, and
/// tears everything down on quit.
@MainActor
final class ServerController: ObservableObject {

    // Configs (persisted as JSON blobs in UserDefaults)
    @Published var seerConfig = SeerServerConfig() { didSet { persist() } }
    @Published var totemConfigs: [TotemNodeConfig] = [] { didSet { persist() } }

    // Environment: local managed processes vs remote prod deployment.
    @Published var environment: AppEnvironment = .local { didSet { persist(); environmentChanged() } }
    @Published var prodSeerURLString = "https://api.seer.services" { didSet { persist() } }
    @Published var prodTotems: [ProdTotemConfig] = [] { didSet { persist() } }
    /// Totems the prod Seer reports via `GET /v1/totems` (refreshed in prod mode).
    @Published var discoveredTotems: [TotemNodeEntry] = []
    @Published var prodSeerHealthy = false
    /// Health per prod totem target id.
    @Published var prodTotemHealthy: [String: Bool] = [:]

    /// Snapshot of the Seer base URL readable off the main actor (API clients).
    private let seerBaseURLBox = LockBox(URL(string: "http://127.0.0.1:8080")!)
    nonisolated var seerBaseURLSnapshot: URL { seerBaseURLBox.value }

    // Runtime
    @Published var seerStatus: ServerStatus = .stopped
    @Published var totemStatus: [UUID: ServerStatus] = [:]
    /// Bumped whenever a managed server transitions into `.running` (or the
    /// prod Seer becomes healthy) — data screens re-fetch on this signal
    /// instead of waiting for the next tab switch.
    @Published private(set) var readyEpoch = 0

    let seerLog = LogBuffer()
    private(set) var totemLogs: [UUID: LogBuffer] = [:]

    private var seerProcess: ManagedProcess?
    private var totemProcesses: [UUID: ManagedProcess] = [:]
    private var healthTask: Task<Void, Never>?

    private enum Keys {
        static let seerConfig = "seer.client.seerConfig"
        static let totemConfigs = "seer.client.totemConfigs"
        static let environment = "seer.client.environment"
        static let prodSeerURL = "seer.client.prodSeerURL"
        static let prodTotems = "seer.client.prodTotems"
    }

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Keys.seerConfig),
           var config = try? JSONDecoder().decode(SeerServerConfig.self, from: data) {
            let storedRepoPath = config.repoPath
            config.repoPath = SeerServerConfig.migratedRepoPath(storedRepoPath)
            seerConfig = config
            if config.repoPath != storedRepoPath,
               let migrated = try? JSONEncoder().encode(config) {
                defaults.set(migrated, forKey: Keys.seerConfig)
            }
        }
        if let data = defaults.data(forKey: Keys.totemConfigs),
           let configs = try? JSONDecoder().decode([TotemNodeConfig].self, from: data) {
            totemConfigs = configs
        }
        if totemConfigs.isEmpty {
            totemConfigs = [TotemNodeConfig()]
        }
        for config in totemConfigs { totemLogs[config.id] = LogBuffer() }

        if let raw = defaults.string(forKey: Keys.environment),
           let saved = AppEnvironment(rawValue: raw) {
            environment = saved
        }
        if let url = defaults.string(forKey: Keys.prodSeerURL), !url.isEmpty {
            prodSeerURLString = url
        }
        if let data = defaults.data(forKey: Keys.prodTotems),
           let saved = try? JSONDecoder().decode([ProdTotemConfig].self, from: data) {
            prodTotems = saved
        }

        startHealthLoop()

        SeerClientAppDelegate.shared.shutdownHandler = { [weak self] in
            self?.stopAllBlocking()
        }
    }

    private func persist() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(seerConfig) {
            defaults.set(data, forKey: Keys.seerConfig)
        }
        if let data = try? JSONEncoder().encode(totemConfigs) {
            defaults.set(data, forKey: Keys.totemConfigs)
        }
        defaults.set(environment.rawValue, forKey: Keys.environment)
        defaults.set(prodSeerURLString, forKey: Keys.prodSeerURL)
        if let data = try? JSONEncoder().encode(prodTotems) {
            defaults.set(data, forKey: Keys.prodTotems)
        }
        seerBaseURLBox.value = seerBaseURL
    }

    private func environmentChanged() {
        discoveredTotems = []
        prodTotemHealthy = [:]
        prodSeerHealthy = false
        if environment == .prod {
            Task { await refreshDiscoveredTotems() }
        }
    }

    func log(for totemId: UUID) -> LogBuffer {
        if let existing = totemLogs[totemId] { return existing }
        let fresh = LogBuffer()
        totemLogs[totemId] = fresh
        return fresh
    }

    var localSeerBaseURL: URL {
        URL(string: "http://\(seerConfig.host):\(seerConfig.port)")!
    }

    /// The Seer this app currently talks to — local process or prod deployment.
    var seerBaseURL: URL {
        switch environment {
        case .local:
            return localSeerBaseURL
        case .prod:
            return URL(string: prodSeerURLString) ?? localSeerBaseURL
        }
    }

    func totemBaseURL(_ config: TotemNodeConfig) -> URL {
        URL(string: "http://\(config.host):\(config.port)")!
    }

    // MARK: Totem targets (environment-aware)

    /// The Totems the Graph/Library screens can inspect right now:
    /// local node configs in local mode; discovered fleet + manual URLs in prod.
    var totemTargets: [TotemTarget] {
        switch environment {
        case .local:
            return totemConfigs.map { config in
                TotemTarget(id: config.id.uuidString, label: config.label,
                            baseURL: totemBaseURL(config), source: .local(config.id),
                            nodeId: config.nodeId.uuidString)
            }
        case .prod:
            var targets: [TotemTarget] = discoveredTotems.compactMap { node in
                guard let url = URL(string: "http://\(node.host):\(node.httpPort)") else { return nil }
                let label = "fleet-\(String(node.totemId.prefix(8)).lowercased())"
                return TotemTarget(id: node.totemId, label: label, baseURL: url,
                                   source: .discovered, nodeId: node.totemId)
            }
            for manual in prodTotems {
                guard let url = URL(string: manual.urlString), url.host() != nil else { continue }
                targets.append(TotemTarget(id: manual.id.uuidString, label: manual.name,
                                           baseURL: url, source: .manual(manual.id)))
            }
            return targets
        }
    }

    /// Pulls the prod Seer's registered fleet so its Totems are inspectable
    /// without manual URL entry.
    func refreshDiscoveredTotems() async {
        guard environment == .prod, let url = URL(string: prodSeerURLString) else { return }
        var request = URLRequest(url: url.appendingPathComponent("v1/totems"))
        request.timeoutInterval = 8
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let body = try? JSONDecoder().decode(TotemNodesResponse.self, from: data) else {
            discoveredTotems = []
            return
        }
        discoveredTotems = body.nodes.filter { $0.isActive }
    }

    func addProdTotem() {
        prodTotems.append(ProdTotemConfig())
    }

    func removeProdTotem(_ config: ProdTotemConfig) {
        prodTotems.removeAll { $0.id == config.id }
    }

    // MARK: Seer lifecycle

    func startSeer() {
        guard seerProcess?.isRunning != true else { return }
        let log = seerLog
        log.clear()
        let process = ManagedProcess(log: log, ports: [seerConfig.port, seerConfig.grpcPort])
        process.onTermination = { [weak self] _ in
            Task { @MainActor in self?.seerStatus = .stopped }
        }
        do {
            try process.launch(
                arguments: ["swift", "run", "seer-server",
                            "--host", seerConfig.host,
                            "--port", String(seerConfig.port),
                            "--grpc-port", String(seerConfig.grpcPort)],
                workingDirectory: URL(fileURLWithPath: seerConfig.repoPath)
            )
            seerProcess = process
            seerStatus = .building
        } catch {
            log.append("launch failed: \(error.localizedDescription)")
            seerStatus = .stopped
        }
    }

    func stopSeer() async {
        seerStatus = .stopped
        await seerProcess?.stop()
        seerProcess = nil
    }

    func restartSeer() async {
        await stopSeer()
        startSeer()
    }

    // MARK: Totem lifecycle

    func startTotem(_ config: TotemNodeConfig) {
        guard totemProcesses[config.id]?.isRunning != true else { return }
        let log = log(for: config.id)
        log.clear()
        let process = ManagedProcess(log: log, ports: [config.port, config.grpcPort])
        process.onTermination = { [weak self] _ in
            Task { @MainActor in self?.totemStatus[config.id] = .stopped }
        }
        var arguments = ["swift", "run", "totem",
                         "--host", config.host,
                         "--port", String(config.port),
                         "--grpc-port", String(config.grpcPort),
                         "--node-id", config.nodeId.uuidString,
                         // Wire to the mothership regardless of whether Seer is
                         // up yet — the registration client reconnects forever.
                         "--mothership-host", seerConfig.host,
                         "--mothership-grpc-port", String(seerConfig.grpcPort)]
        if config.useMLX {
            arguments.append("--use-mlx")
        }
        if config.graphExtraction {
            arguments += ["--graph-backend", config.graphBackend]
            if config.graphBackend == "mlx" {
                arguments += ["--graph-model", config.graphModel]
            }
        } else {
            arguments.append("--no-graph-extraction")
        }
        do {
            try process.launch(
                arguments: arguments,
                workingDirectory: URL(fileURLWithPath: config.repoPath)
            )
            totemProcesses[config.id] = process
            totemStatus[config.id] = .building
        } catch {
            log.append("launch failed: \(error.localizedDescription)")
            totemStatus[config.id] = .stopped
        }
    }

    func stopTotem(_ config: TotemNodeConfig) async {
        totemStatus[config.id] = .stopped
        await totemProcesses[config.id]?.stop()
        totemProcesses[config.id] = nil
    }

    func addTotem() {
        var config = TotemNodeConfig()
        let usedPorts = Set(totemConfigs.flatMap { [$0.port, $0.grpcPort] } + [seerConfig.port, seerConfig.grpcPort])
        var port = 8081
        while usedPorts.contains(port) { port += 1 }
        var grpc = 9090
        while usedPorts.contains(grpc) || grpc == port { grpc += 1 }
        config.port = port
        config.grpcPort = grpc
        totemConfigs.append(config)
        totemLogs[config.id] = LogBuffer()
    }

    func removeTotem(_ config: TotemNodeConfig) async {
        await stopTotem(config)
        totemConfigs.removeAll { $0.id == config.id }
        totemLogs.removeValue(forKey: config.id)
        totemStatus.removeValue(forKey: config.id)
    }

    // MARK: Shutdown

    /// Synchronous teardown for app quit: SIGTERM everything, then one graceful
    /// port sweep across all servers (killListeners SIGTERMs the real server
    /// children under `swift run` and only SIGKILLs after the grace window —
    /// Totems need it to flush their partition tables).
    nonisolated func stopAllBlocking() {
        let processes = MainActor.assumeIsolated {
            ([seerProcess] + totemProcesses.values.map { Optional($0) }).compactMap { $0 }
        }
        for process in processes {
            if let pid = process.pid { kill(pid, SIGTERM) }
        }
        Thread.sleep(forTimeInterval: 1.5)
        for process in processes {
            if let pid = process.pid { kill(pid, SIGKILL) }
        }
        ManagedProcess.killListeners(on: processes.flatMap { $0.ports })
    }

    // MARK: Health polling

    private func startHealthLoop() {
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollHealth()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func pollHealth() async {
        if seerProcess?.isRunning == true {
            let healthy = await Self.checkHealth(url: localSeerBaseURL.appendingPathComponent("health"))
            let previous = seerStatus
            seerStatus = healthy ? .running : (seerStatus == .running ? .unhealthy : .building)
            if seerStatus == .running && previous != .running { readyEpoch += 1 }
        }
        for config in totemConfigs where totemProcesses[config.id]?.isRunning == true {
            let healthy = await Self.checkHealth(url: totemBaseURL(config).appendingPathComponent("health"))
            let previous = totemStatus[config.id] ?? .building
            totemStatus[config.id] = healthy ? .running : (previous == .running ? .unhealthy : .building)
            if healthy && previous != .running { readyEpoch += 1 }
        }

        // Remote deployment health (prod mode).
        if environment == .prod {
            if let url = URL(string: prodSeerURLString) {
                let wasHealthy = prodSeerHealthy
                prodSeerHealthy = await Self.checkHealth(url: url.appendingPathComponent("health"))
                if prodSeerHealthy && !wasHealthy { readyEpoch += 1 }
            }
            if discoveredTotems.isEmpty {
                await refreshDiscoveredTotems()
            }
            for target in totemTargets {
                prodTotemHealthy[target.id] = await Self.checkHealth(
                    url: target.baseURL.appendingPathComponent("health"))
            }
        }
    }

    private static func checkHealth(url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200...299).contains(http.statusCode)
    }
}
