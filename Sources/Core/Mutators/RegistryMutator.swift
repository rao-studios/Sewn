import Conduit
import Foundation

/// Serializes billing stat writes and Totem node tracking.
///
/// Document/group/ownership data is now owned by Totem nodes. This actor
/// retains only two responsibilities:
///   1. `documentStats` — billing earnings and engagement performance
///   2. Totem node metadata — active node set for fan-out routing
actor RegistryMutator {
    private let cache: SeerCache<SeerRegistry>
    private let logger: SeerLogger

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

    init(logger: SeerLogger, walURL: URL? = FilePersistence.getDefaultURL().appendingPathComponent("registry-wal")) {
        self.cache = SeerCache(
            persistence: FilePersistence(key: "registry", kind: .basic, logger: logger.base)
        )
        self.logger = logger
        self.wal          = walURL.flatMap { try? RegistryWAL(url: $0) }
        self.walByteCount = wal?.byteSize ?? 0
    }

    // MARK: - Startup seeding

    nonisolated func seed(_ initial: SeerRegistry) { cache.seed(initial) }

    // MARK: - Snapshot

    nonisolated var snapshot: SeerRegistry? { cache.snapshot }

    // MARK: - Private

    private func loadedRegistry() async -> SeerRegistry {
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

    func accumulatePerformance(_ updates: [DocumentID: Seer.DocumentStats]) async {
        guard !updates.isEmpty else { return }
        var registry = await loadedRegistry()
        registry.addPerformance(updates)
        cache.update(registry)
        appendWAL(.performanceAccumulated(updates.values.map { .init(from: $0) }))
    }

    // MARK: - Owner → Totem cache
    //
    // Records which Totem nodes have stored data for a given ownerId. Populated
    // eagerly from fanoutIndex (on put) and lazily from fanoutLibrary responses.
    // Used to scope library fanouts to only relevant Totems instead of all active nodes.

    private var ownerTotemMap: [String: Set<UUID>] = [:]

    func recordOwnerTotem(ownerId: String, totemId: UUID) {
        ownerTotemMap[ownerId, default: []].insert(totemId)
    }

    func totemNodesForOwner(_ ownerId: String, allNodes: [TotemNode]) -> [TotemNode] {
        guard !ownerId.isEmpty,
              let ids = ownerTotemMap[ownerId], !ids.isEmpty else {
            return allNodes
        }
        let targeted = allNodes.filter { ids.contains($0.totemId) }
        return targeted.isEmpty ? allNodes : targeted
    }

    // MARK: - Totem Node Registry

    private var nodes: [UUID: TotemNode] = [:]

    func registerNode(_ node: TotemNode) {
        var node = node
        // Allow the host to be remapped at runtime (e.g. TOTEM_HOST_OVERRIDE=host.docker.internal
        // when Seer runs in Docker and Totem is on the host machine).
        if let override = ProcessInfo.processInfo.environment["TOTEM_HOST_OVERRIDE"], !override.isEmpty {
            node.host = override
        }
        // Remove any previous entry at the same address — handles the case where
        // a Totem restarts and generates a new UUID (e.g. missing node-id file).
        if let staleId = nodes.first(where: {
            $0.key != node.totemId &&
            $0.value.host == node.host &&
            $0.value.grpcPort == node.grpcPort
        })?.key {
            nodes.removeValue(forKey: staleId)
        }
        nodes[node.totemId] = node
    }

    func heartbeatNode(totemId: UUID) {
        guard var node = nodes[totemId] else { return }
        node.lastSeen = Date()
        nodes[totemId] = node
    }

    func updateNodeAvailability(totemId: UUID, accepting: Bool) {
        guard var node = nodes[totemId] else { return }
        node.acceptingStorage = accepting
        nodes[totemId] = node
    }

    func removeNode(totemId: UUID) {
        nodes.removeValue(forKey: totemId)
    }

    func totemNode(for totemId: UUID) -> TotemNode? {
        guard let n = nodes[totemId], n.isActive else { return nil }
        return n
    }

    var activeNodes: [TotemNode] {
        nodes.values.filter { $0.isActive }
    }

    var availableForStorage: [TotemNode] {
        nodes.values.filter { $0.isActive && $0.acceptingStorage }
    }

    var allNodes: [TotemNode] {
        // Prune nodes not seen in 5 minutes before returning — prevents dead nodes
        // accumulating when a Totem gets a new UUID on restart.
        let cutoff = Date().addingTimeInterval(-300)
        let stale = nodes.filter { $0.value.lastSeen < cutoff }.map(\.key)
        stale.forEach { nodes.removeValue(forKey: $0) }
        return Array(nodes.values)
    }
}

// Conduit's TotemRegistrationServiceImpl writes registration, heartbeat, and
// availability updates through this conformance; the actor methods above are
// the witnesses.
extension RegistryMutator: TotemRegistry {}
