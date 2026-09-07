import Foundation
import SwiftUI

@MainActor
final class GraphViewModel: ObservableObject {

    struct Node: Identifiable, Equatable {
        let entity: GraphEntity
        var position: CGPoint
        var isSeed: Bool

        var id: String { entity.id }
    }

    struct Edge: Identifiable, Equatable {
        let relationship: GraphRelationship
        var id: String { relationship.id }
    }

    // Query state
    @Published var entityQuery = ""
    @Published var textQuery = ""
    @Published var hops = 1
    @Published var kindFilter: String?

    // Result state
    @Published var nodes: [Node] = []
    @Published var edges: [Edge] = []
    @Published var documents: [GraphDocument] = []
    @Published var stats: GraphStats?
    @Published var selectedEntityId: String?
    @Published var renamingEntityId: String?
    @Published var isLoading = false
    @Published var error: String?

    // Trace overlay (test search)
    @Published var traceQuery = ""
    @Published var traceMatchedIds: Set<String> = []
    @Published var traceExpansionEdgeIds: Set<String> = []
    @Published var traceActive = false

    // Node selection target (environment-aware: local config or prod endpoint)
    @Published var target: ThreadTarget?

    private(set) var api: ThreadAPI?
    var ownerId: String = ""

    var selectedEntity: GraphEntity? {
        nodes.first { $0.id == selectedEntityId }?.entity
    }

    var kinds: [String] {
        Array(Set(nodes.map { $0.entity.kind })).sorted()
    }

    func attach(target: ThreadTarget, ownerId: String) {
        self.target = target
        api = ThreadAPI(baseURL: target.baseURL)
        self.ownerId = ownerId
    }

    // MARK: - Fetch

    func fetch() async {
        guard let api else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        // No entity/text query → browse mode: the thread returns the whole
        // graph capped by mention count, so allow a much larger cap.
        let browsing = entityQuery.isEmpty && textQuery.isEmpty
        do {
            let response = try await api.graph(
                ownerId: ownerId,
                entity: entityQuery.isEmpty ? nil : entityQuery,
                query: textQuery.isEmpty ? nil : textQuery,
                kinds: kindFilter.map { [$0] } ?? [],
                hops: hops,
                limit: browsing ? 150 : 30
            )
            apply(response)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func apply(_ response: GraphQueryResponse) {
        let seedIds = Set(response.entities.filter { ($0.score ?? 0) > 0 }.map { $0.id })
        let positions = Self.radialLayout(entities: response.entities,
                                          relationships: response.relationships,
                                          seedIds: seedIds)
        nodes = response.entities.map { entity in
            Node(entity: entity,
                 position: positions[entity.id] ?? .zero,
                 isSeed: seedIds.contains(entity.id))
        }
        edges = response.relationships.map { Edge(relationship: $0) }
        documents = response.documents
        stats = response.stats
        if let selected = selectedEntityId, !nodes.contains(where: { $0.id == selected }) {
            selectedEntityId = nil
        }
    }

    // MARK: - Trace overlay

    func runTrace() async {
        guard let api, !traceQuery.isEmpty else { return }
        do {
            let response = try await api.search(ownerId: ownerId, query: traceQuery)
            traceMatchedIds = Set(response.graph?.matchedEntityIds ?? [])
            traceExpansionEdgeIds = Set(response.graph?.expansionEdgeIds ?? [])
            traceActive = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    func clearTrace() {
        traceActive = false
        traceMatchedIds = []
        traceExpansionEdgeIds = []
    }

    /// Applies a trace overlay from an already-fetched search response — the
    /// Library pane's search shares its single `/v1/search` call with the graph
    /// when both panes target the same thread.
    func applyTrace(query: String, response: SearchResponseBody) {
        traceQuery = query
        traceMatchedIds = Set(response.graph?.matchedEntityIds ?? [])
        traceExpansionEdgeIds = Set(response.graph?.expansionEdgeIds ?? [])
        traceActive = true
    }

    /// Highlights every in-view entity/edge whose provenance includes
    /// `documentId` (reusing the trace overlay) and selects the strongest
    /// match. Fetches the default neighborhood first when the canvas is empty.
    /// Driven by chat source-chip taps in the workspace.
    func highlightDocument(id documentId: String) async {
        if nodes.isEmpty { await fetch() }
        let matched = nodes.filter { $0.entity.documentIds?.contains(documentId) ?? false }
        traceQuery = ""
        traceMatchedIds = Set(matched.map(\.id))
        traceExpansionEdgeIds = Set(edges.filter {
            $0.relationship.documentIds?.contains(documentId) ?? false
        }.map(\.id))
        traceActive = !matched.isEmpty
        selectedEntityId = matched.max {
            ($0.entity.mentionCount ?? 0) < ($1.entity.mentionCount ?? 0)
        }?.id
    }

    // MARK: - Layout

    /// Deterministic radial layout: seeds on ring 0 (or the densest entities when
    /// nothing matched), BFS depth → ring radius, angular slots proportional to
    /// subtree size, all ties broken by id — stable across refreshes.
    static func radialLayout(
        entities: [GraphEntity],
        relationships: [GraphRelationship],
        seedIds: Set<String>
    ) -> [String: CGPoint] {
        guard !entities.isEmpty else { return [:] }
        let ringSpacing: CGFloat = 190
        let center = CGPoint(x: 0, y: 0)

        // Adjacency
        var adjacency: [String: Set<String>] = [:]
        for relationship in relationships {
            adjacency[relationship.subjectId, default: []].insert(relationship.objectId)
            adjacency[relationship.objectId, default: []].insert(relationship.subjectId)
        }

        // Seeds: matched entities, else the highest-mention entities.
        var seeds = entities.filter { seedIds.contains($0.id) }.map { $0.id }.sorted()
        if seeds.isEmpty {
            seeds = entities
                .sorted { ($0.mentionCount ?? 0, $1.id) > ($1.mentionCount ?? 0, $0.id) }
                .prefix(1)
                .map { $0.id }
        }

        // BFS depth per node (unreached nodes go on an outer ring).
        var depth: [String: Int] = [:]
        var frontier = seeds
        for seed in seeds { depth[seed] = 0 }
        var level = 0
        while !frontier.isEmpty {
            level += 1
            var next: [String] = []
            for id in frontier.sorted() {
                for neighbor in (adjacency[id] ?? []).sorted() where depth[neighbor] == nil {
                    depth[neighbor] = level
                    next.append(neighbor)
                }
            }
            frontier = next
        }
        let maxDepth = (depth.values.max() ?? 0) + 1
        for entity in entities where depth[entity.id] == nil {
            depth[entity.id] = maxDepth
        }

        // Ring membership, id-sorted for determinism.
        var rings: [Int: [String]] = [:]
        for entity in entities {
            rings[depth[entity.id]!, default: []].append(entity.id)
        }

        var positions: [String: CGPoint] = [:]
        for (ring, members) in rings {
            let sorted = members.sorted()
            let radius = ring == 0 && sorted.count == 1 ? 0 : ringSpacing * CGFloat(ring) + (ring == 0 ? 90 : 0)
            for (index, id) in sorted.enumerated() {
                let angle = (2 * .pi * CGFloat(index) / CGFloat(sorted.count)) - .pi / 2
                positions[id] = CGPoint(
                    x: center.x + radius * cos(angle),
                    y: center.y + radius * sin(angle)
                )
            }
        }
        return positions
    }
}
