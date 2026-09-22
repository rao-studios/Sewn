import Conduit
import Foundation
import RaoStack

/// Which registered Thread nodes a request may reach.
///
/// One Sewn serves every Rao app on a shared ~/.rao stack, and each app has
/// its own Thread. A node belongs to the app whose stack secret it registered
/// with (`ThreadNode.app`, recorded by Conduit); a request belongs to the app
/// whose secret it carried (`SewnRequest.callerApp`). Every fan-out asks the
/// registry for nodes *in* a scope, so no call site can reach another app's
/// Thread by forgetting to filter. `Sewn.nodeScope(for:)` picks the scope.
enum NodeScope: Sendable, Equatable {
    /// Every node: an open or one-app Sewn, where there is only one caller.
    case all
    /// Only the nodes that registered with this app's secret.
    case app(RaoApp)
    /// No node at all: a shared Sewn asked on behalf of no app. Fails closed.
    case none

    func admits(_ node: ThreadNode) -> Bool {
        switch self {
        case .all: return true
        case .app(let app): return node.app == app.rawValue
        case .none: return false
        }
    }
}

/// Serializes billing stat writes and Thread node tracking.
///
/// Document/group/ownership data is now owned by Thread nodes. This actor
/// retains only two responsibilities:
///   1. `documentStats` — billing earnings and engagement performance
///   2. Thread node metadata — active node set for fan-out routing, read
///      through a `NodeScope` (nodes are in memory only, never persisted:
///      a restarted Sewn learns them again as each Thread re-registers)
actor RegistryMutator {
    private let cache: SewnCache<SewnRegistry>
    private let logger: SewnLogger

    // MARK: - WAL (billing-only)
    //
    // Billing mutations (accumulateEarnings, accumulatePerformance) append a small
    // binary record to the WAL instead of triggering a full PropertyList rewrite.
    // A checkpoint fires when the WAL grows beyond `walCheckpointThreshold`.

    private var wal:          RegistryWAL?
    private var walByteCount: Int = 0
    static let walCheckpointThreshold = 16 * 1024 * 1024

    // MARK: - Debounced disk saves (WAL-unavailable fallback)

    private var registryDirty = false
    private var flushTask: Task<Void, Never>?

    init(logger: SewnLogger, walURL: URL? = FilePersistence.getDefaultURL().appendingPathComponent("registry-wal")) {
        self.cache = SewnCache(
            persistence: FilePersistence(key: "registry", kind: .basic, logger: logger.base)
        )
        self.logger = logger
        self.wal          = walURL.flatMap { try? RegistryWAL(url: $0) }
        self.walByteCount = wal?.byteSize ?? 0
    }

    // MARK: - Startup seeding

    nonisolated func seed(_ initial: SewnRegistry) { cache.seed(initial) }

    // MARK: - Snapshot

    nonisolated var snapshot: SewnRegistry? { cache.snapshot }

    // MARK: - Private

    private func loadedRegistry() async -> SewnRegistry {
        return await cache.load { .init() }
    }

    private func appendWAL(_ record: RegistryWALRecord) {
        if let w = wal {
            try? w.append(record)
            walByteCount = w.byteSize
            if walByteCount >= Self.walCheckpointThreshold { checkpoint() }
        } else {
            scheduleSave()
        }
    }

    private func appendWALBatch(_ records: [RegistryWALRecord]) {
        if let w = wal {
            for r in records { try? w.append(r) }
            walByteCount = w.byteSize
            if walByteCount >= Self.walCheckpointThreshold { checkpoint() }
        } else {
            scheduleSave()
        }
    }

    private func checkpoint() {
        guard let registry = cache.snapshot else { return }
        walByteCount  = 0
        registryDirty = false
        flushTask?.cancel()
        flushTask     = nil
        let capturedWal = wal
        Task {
            await self.cache.saveNow(registry)
            try? capturedWal?.truncate()
        }
    }

    func flushForShutdown() async {
        guard let registry = cache.snapshot else { return }
        await cache.saveNow(registry)
        try? wal?.truncate()
        walByteCount  = 0
        registryDirty = false
        flushTask?.cancel()
        flushTask     = nil
    }

    private func scheduleSave() {
        registryDirty = true
        guard flushTask == nil else { return }
        flushTask = Task {
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
            self.flushIfDirty()
        }
    }

    private func flushIfDirty() {
        guard registryDirty, let registry = cache.snapshot else {
            flushTask = nil
            return
        }
        cache.saveAsync(registry)
        registryDirty = false
        flushTask = nil
    }

    // MARK: - Document Stats (billing)

    func accumulateEarnings(_ earnings: [DocumentID: Gita.Credits]) async {
        guard !earnings.isEmpty else { return }
        var registry = await loadedRegistry()
        registry.addEarnings(earnings)
        cache.update(registry)
        appendWAL(.earningsAccumulated(earnings.map { ($0.key, $0.value) }))
    }

    func accumulatePerformance(_ updates: [DocumentID: Sewn.DocumentStats]) async {
        guard !updates.isEmpty else { return }
        var registry = await loadedRegistry()
        registry.addPerformance(updates)
        cache.update(registry)
        appendWAL(.performanceAccumulated(updates.values.map { .init(from: $0) }))
    }

    // MARK: - Owner → Thread cache
    //
    // Records which Thread nodes have stored data for a given ownerId. Populated
    // eagerly from fanoutIndex (on put) and lazily from fanoutLibrary responses.
    // Used to scope library fanouts to only relevant Threads instead of all active nodes.

    private var ownerThreadMap: [String: Set<UUID>] = [:]

    func recordOwnerThread(ownerId: String, threadId: UUID) {
        ownerThreadMap[ownerId, default: []].insert(threadId)
    }

    /// The nodes among `scopedNodes` known to hold `ownerId`'s data, or all
    /// of `scopedNodes` when none are known. Always a subset of its input, so
    /// pass a list already scoped to the caller (`activeNodes(in:)`): the
    /// owner map is keyed by owner alone, across every app.
    func threadNodesForOwner(_ ownerId: String, scopedNodes: [ThreadNode]) -> [ThreadNode] {
        guard !ownerId.isEmpty,
              let ids = ownerThreadMap[ownerId], !ids.isEmpty else {
            return scopedNodes
        }
        let targeted = scopedNodes.filter { ids.contains($0.threadId) }
        return targeted.isEmpty ? scopedNodes : targeted
    }

    // MARK: - Thread Node Registry

    private var nodes: [UUID: ThreadNode] = [:]

    func registerNode(_ node: ThreadNode) {
        var node = node
        // Allow the host to be remapped at runtime (e.g. THREAD_HOST_OVERRIDE=host.docker.internal
        // when Sewn runs in Docker and Thread is on the host machine).
        if let override = ProcessInfo.processInfo.environment["THREAD_HOST_OVERRIDE"], !override.isEmpty {
            node.host = override
        }
        // A node id belongs to the app that registered it first. Conduit's
        // registration service refuses another app's Register for it already;
        // this is the registry's own guard, so no path can re-home a node.
        if let existing = nodes[node.threadId], existing.app != node.app {
            logger.warning(
                label: "Thread Registry",
                "Ignored registration of Thread \(node.threadId) for \(node.app ?? "no app") — it is registered for \(existing.app ?? "no app")",
                service: .sewn)
            return
        }
        // Remove any previous entry of the same app at the same address —
        // handles the case where a Thread restarts and generates a new UUID
        // (e.g. missing node-id file). Another app's Thread that happens to
        // share the address is its own node and stays.
        if let staleId = nodes.first(where: {
            $0.key != node.threadId &&
            $0.value.app == node.app &&
            $0.value.host == node.host &&
            $0.value.grpcPort == node.grpcPort
        })?.key {
            nodes.removeValue(forKey: staleId)
        }
        nodes[node.threadId] = node
    }

    /// The node registered as `threadId`, active or not. Conduit's
    /// registration service reads it to check that an RPC comes from the app
    /// the node belongs to. Spelled `async` to match `ThreadRegistry`'s
    /// requirement exactly: the protocol's extension default (which knows no
    /// nodes) would otherwise win overload resolution at every call site.
    func registeredNode(threadId: UUID) async -> ThreadNode? {
        nodes[threadId]
    }

    func heartbeatNode(threadId: UUID) {
        guard var node = nodes[threadId] else { return }
        node.lastSeen = Date()
        nodes[threadId] = node
    }

    func updateNodeAvailability(threadId: UUID, accepting: Bool) {
        guard var node = nodes[threadId] else { return }
        node.acceptingStorage = accepting
        nodes[threadId] = node
    }

    func removeNode(threadId: UUID) {
        nodes.removeValue(forKey: threadId)
    }

    /// Nodes in `scope` that heartbeated within the last minute.
    func activeNodes(in scope: NodeScope) -> [ThreadNode] {
        nodes.values.filter { $0.isActive && scope.admits($0) }
    }

    /// Active nodes in `scope` that accept new documents.
    func availableForStorage(in scope: NodeScope) -> [ThreadNode] {
        nodes.values.filter { $0.isActive && $0.acceptingStorage && scope.admits($0) }
    }

    /// Every node in `scope`, active or not.
    func allNodes(in scope: NodeScope) -> [ThreadNode] {
        // Prune nodes not seen in 5 minutes before returning — prevents dead nodes
        // accumulating when a Thread gets a new UUID on restart. Pruning is
        // housekeeping for the whole registry, whatever the caller's scope.
        let cutoff = Date().addingTimeInterval(-300)
        let stale = nodes.filter { $0.value.lastSeen < cutoff }.map(\.key)
        stale.forEach { nodes.removeValue(forKey: $0) }
        return nodes.values.filter { scope.admits($0) }
    }
}

// Conduit's ThreadRegistrationServiceImpl writes registration, heartbeat, and
// availability updates through this conformance, and reads `registeredNode`
// for its ownership checks; the actor methods above are the witnesses.
extension RegistryMutator: ThreadRegistry {}
