import Conduit
import Foundation
import Hummingbird

struct ThreadNodeStats: Codable {
    let documentCount: Int
    let groupCount: Int
    let ownerCount: Int
    let availableDocumentCount: Int

    enum CodingKeys: String, CodingKey {
        case documentCount          = "document_count"
        case groupCount             = "group_count"
        case ownerCount             = "owner_count"
        case availableDocumentCount = "available_document_count"
    }
}

struct ThreadNodesResponse: Codable {
    let mothershipId: String
    let totalDocumentCount: Int
    let totalGroupCount: Int
    let nodes: [ThreadNodeEntry]
    let enabled: Bool

    enum CodingKeys: String, CodingKey {
        case mothershipId      = "mothership_id"
        case totalDocumentCount = "total_document_count"
        case totalGroupCount    = "total_group_count"
        case nodes
        case enabled
    }
}

struct ThreadNodeEntry: Codable {
    let threadId: String
    let host: String
    let grpcPort: Int
    let httpPort: Int
    let lastSeen: Date
    let isActive: Bool
    let acceptingStorage: Bool
    let stats: ThreadNodeStats?
    /// The app the node registered for on a shared stack; left out when nil.
    let app: String?

    enum CodingKeys: String, CodingKey {
        case threadId         = "thread_id"
        case host
        case grpcPort        = "grpc_port"
        case httpPort        = "http_port"
        case lastSeen        = "last_seen"
        case isActive        = "is_active"
        case acceptingStorage = "accepting_storage"
        case stats
        case app
    }
}

/// `GET /v1/threads` — the caller's Thread nodes. On a shared stack, only the
/// calling app's; everywhere else, every node, as before.
func registerThreadNodesRoute(_ router: some RouterMethods<SewnRequestContext>, _ sewn: Sewn) {
    router.get("/v1/threads") { _, context async throws -> ThreadNodesResponse in
        let all = await sewn.nonisolatedRegistryMutator.allNodes(in: sewn.nodeScope(for: context.callerApp))
        let statsMap = await sewn.fanoutStats(app: context.callerApp)

        var totalDocumentCount = 0
        var totalGroupCount = 0

        let entries = all.map { node in
            let nodeStats: ThreadNodeStats?
            if let s = statsMap[node.threadId.uuidString] {
                nodeStats = ThreadNodeStats(
                    documentCount: Int(s.documentCount),
                    groupCount: Int(s.groupCount),
                    ownerCount: Int(s.ownerCount),
                    availableDocumentCount: Int(s.availableDocumentCount)
                )
                totalDocumentCount += Int(s.documentCount)
                totalGroupCount    += Int(s.groupCount)
            } else {
                nodeStats = nil
            }
            return ThreadNodeEntry(
                threadId: node.threadId.uuidString,
                host: node.host,
                grpcPort: node.grpcPort,
                httpPort: node.httpPort,
                lastSeen: node.lastSeen,
                isActive: node.isActive,
                acceptingStorage: node.acceptingStorage,
                stats: nodeStats,
                app: node.app
            )
        }

        return ThreadNodesResponse(
            mothershipId: sewn.nodeId.uuidString,
            totalDocumentCount: totalDocumentCount,
            totalGroupCount: totalGroupCount,
            nodes: entries,
            enabled: !all.isEmpty
        )
    }
}
