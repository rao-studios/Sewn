import Conduit
import Foundation

/// Serializes billing stat writes and Thread node tracking.
///
/// Document/group/ownership data is now owned by Thread nodes. This actor
/// retains only two responsibilities:
///   1. `documentStats` — billing earnings and engagement performance
///   2. Thread node metadata — active node set for fan-out routing
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

    func threadNodesForOwner(_ ownerId: String, allNodes: [ThreadNode]) -> [ThreadNode] {
        guard !ownerId.isEmpty,
              let ids = ownerThreadMap[ownerId], !ids.isEmpty else {
            return allNodes
        }
        let targeted = allNodes.filter { ids.contains($0.threadId) }
        return targeted.isEmpty ? allNodes : targeted
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
        // Remove any previous entry at the same address — handles the case where
        // a Thread restarts and generates a new UUID (e.g. missing node-id file).
        if let staleId = nodes.first(where: {
            $0.key != node.threadId &&
            $0.value.host == node.host &&
            $0.value.grpcPort == node.grpcPort
        })?.key {
            nodes.removeValue(forKey: staleId)
        }
        nodes[node.threadId] = node
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

    func threadNode(for threadId: UUID) -> ThreadNode? {
        guard let n = nodes[threadId], n.isActive else { return nil }
        return n
    }

    var activeNodes: [ThreadNode] {
        nodes.values.filter { $0.isActive }
    }

    var availableForStorage: [ThreadNode] {
        nodes.values.filter { $0.isActive && $0.acceptingStorage }
    }

    var allNodes: [ThreadNode] {
        // Prune nodes not seen in 5 minutes before returning — prevents dead nodes
        // accumulating when a Thread gets a new UUID on restart.
        let cutoff = Date().addingTimeInterval(-300)
        let stale = nodes.filter { $0.value.lastSeen < cutoff }.map(\.key)
        stale.forEach { nodes.removeValue(forKey: $0) }
        return Array(nodes.values)
    }
}

// Conduit's ThreadRegistrationServiceImpl writes registration, heartbeat, and
// availability updates through this conformance; the actor methods above are
// the witnesses.
extension RegistryMutator: ThreadRegistry {}
