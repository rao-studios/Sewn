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

struct SewnServerConfig: Codable, Equatable {
    static let defaultRepoPath = NSString(
        string: "~/Documents/rao/repositories/Sewn").expandingTildeInPath

    var repoPath: String = defaultRepoPath
    var host: String = "127.0.0.1"
    var port: Int = 8080
    var grpcPort: Int = 9091
}

struct ThreadNodeConfig: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var repoPath: String = NSString(string: "~/Documents/rao/repositories/Thread").expandingTildeInPath
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

    var label: String { "thread-\(String(nodeId.uuidString.prefix(8)).lowercased())" }

    init() {}

    /// Tolerant decoding: every field falls back to its default when absent so
    /// configs persisted by older builds (no `graphBackend` key) keep decoding —
    /// a hard failure here would silently reset node identities.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ThreadNodeConfig()
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

/// A manually configured remote Thread endpoint (prod mode).
struct ProdThreadConfig: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String = "prod-thread"
    var urlString: String = "http://"
}

/// A Thread the Graph/Library screens can target, regardless of environment.
struct ThreadTarget: Identifiable, Equatable {
    enum Source: Equatable { case local(UUID), discovered, manual(UUID) }
    let id: String
    let label: String
    let baseURL: URL
    let source: Source
    /// The thread's node UUID as registered with Sewn — what the `sewn` request
    /// block's `personal_thread_id`/`thread_ids` expect. Nil for manual endpoints
    /// whose node identity is unknown (Sewn then picks a storage thread itself).
    var nodeId: String? = nil
}

enum ServerStatus: Equatable {
    case stopped
    case building     // swift run compiling, health not yet answering
    case running
    case unhealthy    // process alive but health check failing after it was up

    var color: Color {
        switch self {
        case .stopped:   return Color.sewnInk.opacity(0.25)
        case .building:  return Color.sewnGold
        case .running:   return Color.sewnGreen
        case .unhealthy: return Color.sewnError
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

/// Owns every managed server process: one Sewn, N Threads. Persists configs,
/// launches `swift run` in the configured repo checkouts, polls health, and
/// tears everything down on quit.
@MainActor
final class ServerController: ObservableObject {

    // Configs (persisted as JSON blobs in UserDefaults)
    @Published var sewnConfig = SewnServerConfig() { didSet { persist() } }
    @Published var threadConfigs: [ThreadNodeConfig] = [] { didSet { persist() } }

    // Environment: local managed processes vs remote prod deployment.
    @Published var environment: AppEnvironment = .local { didSet { persist(); environmentChanged() } }
    @Published var prodSewnURLString = "https://api.seer.services" { didSet { persist() } }
    @Published var prodThreads: [ProdThreadConfig] = [] { didSet { persist() } }
    /// Threads the prod Sewn reports via `GET /v1/threads` (refreshed in prod mode).
    @Published var discoveredThreads: [ThreadNodeEntry] = []
    @Published var prodSewnHealthy = false
    /// Health per prod thread target id.
    @Published var prodThreadHealthy: [String: Bool] = [:]

    /// Snapshot of the Sewn base URL readable off the main actor (API clients).
    private let sewnBaseURLBox = LockBox(URL(string: "http://127.0.0.1:8080")!)
    nonisolated var sewnBaseURLSnapshot: URL { sewnBaseURLBox.value }

    // Runtime
    @Published var sewnStatus: ServerStatus = .stopped
    @Published var threadStatus: [UUID: ServerStatus] = [:]
    /// Bumped whenever a managed server transitions into `.running` (or the
    /// prod Sewn becomes healthy) — data screens re-fetch on this signal
    /// instead of waiting for the next tab switch.
    @Published private(set) var readyEpoch = 0

    let sewnLog = LogBuffer()
    private(set) var threadLogs: [UUID: LogBuffer] = [:]

    private var sewnProcess: ManagedProcess?
    private var threadProcesses: [UUID: ManagedProcess] = [:]
    private var healthTask: Task<Void, Never>?

    private enum Keys {
        static let sewnConfig = "sewn.client.sewnConfig"
        static let threadConfigs = "sewn.client.threadConfigs"
        static let environment = "sewn.client.environment"
        static let prodSewnURL = "sewn.client.prodSewnURL"
        static let prodThreads = "sewn.client.prodThreads"
    }

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Keys.sewnConfig),
           let config = try? JSONDecoder().decode(SewnServerConfig.self, from: data) {
            sewnConfig = config
        }
        if let data = defaults.data(forKey: Keys.threadConfigs),
           let configs = try? JSONDecoder().decode([ThreadNodeConfig].self, from: data) {
            threadConfigs = configs
        }
        if threadConfigs.isEmpty {
            threadConfigs = [ThreadNodeConfig()]
        }
        for config in threadConfigs { threadLogs[config.id] = LogBuffer() }

        if let raw = defaults.string(forKey: Keys.environment),
           let saved = AppEnvironment(rawValue: raw) {
            environment = saved
        }
        if let url = defaults.string(forKey: Keys.prodSewnURL), !url.isEmpty {
            prodSewnURLString = url
        }
        if let data = defaults.data(forKey: Keys.prodThreads),
           let saved = try? JSONDecoder().decode([ProdThreadConfig].self, from: data) {
            prodThreads = saved
        }

        startHealthLoop()

        SewnClientAppDelegate.shared.shutdownHandler = { [weak self] in
            self?.stopAllBlocking()
        }
    }

    private func persist() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(sewnConfig) {
            defaults.set(data, forKey: Keys.sewnConfig)
        }
        if let data = try? JSONEncoder().encode(threadConfigs) {
            defaults.set(data, forKey: Keys.threadConfigs)
        }
        defaults.set(environment.rawValue, forKey: Keys.environment)
        defaults.set(prodSewnURLString, forKey: Keys.prodSewnURL)
        if let data = try? JSONEncoder().encode(prodThreads) {
            defaults.set(data, forKey: Keys.prodThreads)
        }
        sewnBaseURLBox.value = sewnBaseURL
    }

    private func environmentChanged() {
        discoveredThreads = []
        prodThreadHealthy = [:]
        prodSewnHealthy = false
        if environment == .prod {
            Task { await refreshDiscoveredThreads() }
        }
    }

    func log(for threadId: UUID) -> LogBuffer {
        if let existing = threadLogs[threadId] { return existing }
        let fresh = LogBuffer()
        threadLogs[threadId] = fresh
        return fresh
    }

    var localSewnBaseURL: URL {
        URL(string: "http://\(sewnConfig.host):\(sewnConfig.port)")!
    }

    /// The Sewn this app currently talks to — local process or prod deployment.
    var sewnBaseURL: URL {
        switch environment {
        case .local:
            return localSewnBaseURL
        case .prod:
            return URL(string: prodSewnURLString) ?? localSewnBaseURL
        }
    }

    func threadBaseURL(_ config: ThreadNodeConfig) -> URL {
        URL(string: "http://\(config.host):\(config.port)")!
    }

    // MARK: Thread targets (environment-aware)

    /// The Threads the Graph/Library screens can inspect right now:
    /// local node configs in local mode; discovered fleet + manual URLs in prod.
    var threadTargets: [ThreadTarget] {
        switch environment {
        case .local:
            return threadConfigs.map { config in
                ThreadTarget(id: config.id.uuidString, label: config.label,
                            baseURL: threadBaseURL(config), source: .local(config.id),
                            nodeId: config.nodeId.uuidString)
            }
        case .prod:
            var targets: [ThreadTarget] = discoveredThreads.compactMap { node in
                guard let url = URL(string: "http://\(node.host):\(node.httpPort)") else { return nil }
                let label = "fleet-\(String(node.threadId.prefix(8)).lowercased())"
                return ThreadTarget(id: node.threadId, label: label, baseURL: url,
                                   source: .discovered, nodeId: node.threadId)
            }
            for manual in prodThreads {
                guard let url = URL(string: manual.urlString), url.host() != nil else { continue }
                targets.append(ThreadTarget(id: manual.id.uuidString, label: manual.name,
                                           baseURL: url, source: .manual(manual.id)))
            }
            return targets
        }
    }

    /// Pulls the prod Sewn's registered fleet so its Threads are inspectable
    /// without manual URL entry.
    func refreshDiscoveredThreads() async {
        guard environment == .prod, let url = URL(string: prodSewnURLString) else { return }
        var request = URLRequest(url: url.appendingPathComponent("v1/threads"))
        request.timeoutInterval = 8
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let body = try? JSONDecoder().decode(ThreadNodesResponse.self, from: data) else {
            discoveredThreads = []
            return
        }
        discoveredThreads = body.nodes.filter { $0.isActive }
    }

    func addProdThread() {
        prodThreads.append(ProdThreadConfig())
    }

    func removeProdThread(_ config: ProdThreadConfig) {
        prodThreads.removeAll { $0.id == config.id }
    }

    // MARK: Sewn lifecycle

    func startSewn() {
        guard sewnProcess?.isRunning != true else { return }
        let log = sewnLog
        log.clear()
        let process = ManagedProcess(log: log, ports: [sewnConfig.port, sewnConfig.grpcPort])
        process.onTermination = { [weak self] _ in
            Task { @MainActor in self?.sewnStatus = .stopped }
        }
        do {
            try process.launch(
                arguments: ["swift", "run", "sewn-server",
                            "--host", sewnConfig.host,
                            "--port", String(sewnConfig.port),
                            "--grpc-port", String(sewnConfig.grpcPort)],
                workingDirectory: URL(fileURLWithPath: sewnConfig.repoPath)
            )
            sewnProcess = process
            sewnStatus = .building
        } catch {
            log.append("launch failed: \(error.localizedDescription)")
            sewnStatus = .stopped
        }
    }

    func stopSewn() async {
        sewnStatus = .stopped
        await sewnProcess?.stop()
        sewnProcess = nil
    }

    func restartSewn() async {
        await stopSewn()
        startSewn()
    }

    // MARK: Thread lifecycle

    func startThread(_ config: ThreadNodeConfig) {
        guard threadProcesses[config.id]?.isRunning != true else { return }
        let log = log(for: config.id)
        log.clear()
        let process = ManagedProcess(log: log, ports: [config.port, config.grpcPort])
        process.onTermination = { [weak self] _ in
            Task { @MainActor in self?.threadStatus[config.id] = .stopped }
        }
        var arguments = ["swift", "run", "thread",
                         "--host", config.host,
                         "--port", String(config.port),
                         "--grpc-port", String(config.grpcPort),
                         "--node-id", config.nodeId.uuidString,
                         // Wire to the mothership regardless of whether Sewn is
                         // up yet — the registration client reconnects forever.
                         "--mothership-host", sewnConfig.host,
                         "--mothership-grpc-port", String(sewnConfig.grpcPort)]
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
            threadProcesses[config.id] = process
            threadStatus[config.id] = .building
        } catch {
            log.append("launch failed: \(error.localizedDescription)")
            threadStatus[config.id] = .stopped
        }
    }

    func stopThread(_ config: ThreadNodeConfig) async {
        threadStatus[config.id] = .stopped
        await threadProcesses[config.id]?.stop()
        threadProcesses[config.id] = nil
    }

    func addThread() {
        var config = ThreadNodeConfig()
        let usedPorts = Set(threadConfigs.flatMap { [$0.port, $0.grpcPort] } + [sewnConfig.port, sewnConfig.grpcPort])
        var port = 8081
        while usedPorts.contains(port) { port += 1 }
        var grpc = 9090
        while usedPorts.contains(grpc) || grpc == port { grpc += 1 }
        config.port = port
        config.grpcPort = grpc
        threadConfigs.append(config)
        threadLogs[config.id] = LogBuffer()
    }

    func removeThread(_ config: ThreadNodeConfig) async {
        await stopThread(config)
        threadConfigs.removeAll { $0.id == config.id }
        threadLogs.removeValue(forKey: config.id)
        threadStatus.removeValue(forKey: config.id)
    }

    // MARK: Shutdown

    /// Synchronous teardown for app quit: SIGTERM everything, then one graceful
    /// port sweep across all servers (killListeners SIGTERMs the real server
    /// children under `swift run` and only SIGKILLs after the grace window —
    /// Threads need it to flush their partition tables).
    nonisolated func stopAllBlocking() {
        let processes = MainActor.assumeIsolated {
            ([sewnProcess] + threadProcesses.values.map { Optional($0) }).compactMap { $0 }
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
        if sewnProcess?.isRunning == true {
            let healthy = await Self.checkHealth(url: localSewnBaseURL.appendingPathComponent("health"))
            let previous = sewnStatus
            sewnStatus = healthy ? .running : (sewnStatus == .running ? .unhealthy : .building)
            if sewnStatus == .running && previous != .running { readyEpoch += 1 }
        }
        for config in threadConfigs where threadProcesses[config.id]?.isRunning == true {
            let healthy = await Self.checkHealth(url: threadBaseURL(config).appendingPathComponent("health"))
            let previous = threadStatus[config.id] ?? .building
            threadStatus[config.id] = healthy ? .running : (previous == .running ? .unhealthy : .building)
            if healthy && previous != .running { readyEpoch += 1 }
        }

        // Remote deployment health (prod mode).
        if environment == .prod {
            if let url = URL(string: prodSewnURLString) {
                let wasHealthy = prodSewnHealthy
                prodSewnHealthy = await Self.checkHealth(url: url.appendingPathComponent("health"))
                if prodSewnHealthy && !wasHealthy { readyEpoch += 1 }
            }
            if discoveredThreads.isEmpty {
                await refreshDiscoveredThreads()
            }
            for target in threadTargets {
                prodThreadHealthy[target.id] = await Self.checkHealth(
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
