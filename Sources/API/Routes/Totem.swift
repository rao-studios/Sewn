import Conduit
import Foundation
import Hummingbird

struct TotemNodeStats: Codable {
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

struct TotemNodesResponse: Codable {
    let mothershipId: String
    let totalDocumentCount: Int
    let totalGroupCount: Int
    let nodes: [TotemNodeEntry]
    let enabled: Bool

    enum CodingKeys: String, CodingKey {
        case mothershipId      = "mothership_id"
        case totalDocumentCount = "total_document_count"
        case totalGroupCount    = "total_group_count"
        case nodes
        case enabled
    }
}

struct TotemNodeEntry: Codable {
    let totemId: String
    let host: String
    let grpcPort: Int
    let httpPort: Int
    let lastSeen: Date
    let isActive: Bool
    let acceptingStorage: Bool
    let stats: TotemNodeStats?

    enum CodingKeys: String, CodingKey {
        case totemId         = "totem_id"
        case host
        case grpcPort        = "grpc_port"
        case httpPort        = "http_port"
        case lastSeen        = "last_seen"
        case isActive        = "is_active"
        case acceptingStorage = "accepting_storage"
        case stats
    }
}

func registerTotemNodesRoute(_ router: some RouterMethods<SeerRequestContext>, _ seer: Seer) {
    router.get("/v1/totems") { _, _ async throws -> TotemNodesResponse in
        let all = await seer.nonisolatedRegistryMutator.allNodes
        let statsMap = await seer.fanoutStats()

        var totalDocumentCount = 0
        var totalGroupCount = 0

        let entries = all.map { node in
            let nodeStats: TotemNodeStats?
            if let s = statsMap[node.totemId.uuidString] {
                nodeStats = TotemNodeStats(
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
            return TotemNodeEntry(
                totemId: node.totemId.uuidString,
                host: node.host,
                grpcPort: node.grpcPort,
                httpPort: node.httpPort,
                lastSeen: node.lastSeen,
                isActive: node.isActive,
                acceptingStorage: node.acceptingStorage,
                stats: nodeStats
            )
        }

        return TotemNodesResponse(
            mothershipId: seer.nodeId.uuidString,
            totalDocumentCount: totalDocumentCount,
            totalGroupCount: totalGroupCount,
            nodes: entries,
            enabled: !all.isEmpty
        )
    }
}
