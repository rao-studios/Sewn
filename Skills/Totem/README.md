# Totem — Distributed Vector Search Integration

Totem is Seer's vector search backend. Each Totem node is an independently deployed Swift server that holds HNSW graphs, PQ codebooks, and document partition data. Seer connects to Totem nodes as a **mothership**: it fans out all search, index, remove, and library requests across all registered nodes.

For the full Totem implementation, see the [Totem repository](https://github.com/riteshpakala/Totem).

---

## Registration & Session Lifecycle

Totem nodes connect to Seer (not the other way around). Seer listens on **port 9091** (gRPC) via `MothershipRegistrationService`.

```
Totem                          Seer
  │                              │
  │── register() ───────────────►│  sends totemId, host, grpcPort, httpPort
  │                              │  Seer stores node in RegistryMutator
  │                              │
  │── session() ────────────────►│  opens bidirectional stream
  │◄── TotemSessionMessage ──────│  Seer sends fan-out request payloads
  │── TotemSessionMessage ──────►│  Totem replies with results
  │   (ping every 30s)           │  Seer matches reply by correlationID
  │                              │
  │── updateAvailability() ─────►│  Totem signals acceptingStorage true/false
```

A Totem node is considered **active** while its session stream is open. Seer marks it inactive when the stream closes or times out. Only active nodes receive fan-out.

---

## Fan-Out Primitives

All fan-out is in `Sources/GRPC/Seer+TotemFanout.swift`:

| Method | Description |
|--------|-------------|
| `fanoutSearch(query:embedding:request:)` | Search all active nodes; merge + re-rank results by distance |
| `fanoutIndex(partitions:request:)` | Index document partitions across all nodes accepting storage |
| `fanoutRemove(documentId:ownerId:)` | Soft-delete a document across all nodes |
| `fanoutLibrary(ownerId:page:)` | Paginated document library from all nodes |
| `fanoutDocumentMetadata(partitionId:)` | Fetch opaque metadata for one partition (first node wins) |
| `fanoutDocumentNodes(documentId:ownerId:)` | Fetch HNSW nodes for a document (all nodes, deduplicated) |

Search fan-out is concurrent (`withThrowingTaskGroup`). A node failure is logged but does not abort the entire request — partial results are merged.

---

## gRPC Services on Totem

Totem exposes three gRPC services, reachable both directly and via the session stream:

| Service | RPCs |
|---------|------|
| `TotemQuery` | `search`, `index`, `remove`, `library` |
| `TotemLibrary` | `library` (paginated group listing) |
| `TotemHNSW` | `stats`, `graph`, `node`, `nodeBatch`, `deleteNode` |

The session stream wraps these as `TotemSessionMessage` payloads with a `correlationID` for matching replies.

---

## Session Message Envelope

```protobuf
message TotemSessionMessage {
  string correlation_id = 1;
  string totem_id       = 2;
  oneof payload {
    // Requests (Seer → Totem)
    TotemSearchRequest        search_request         = 10;
    TotemIndexRequest         index_request          = 11;
    TotemRemoveRequest        remove_request         = 12;
    TotemLibraryRequest       library_request        = 13;
    TotemHNSWStatsRequest     hnsw_stats_request     = 14;
    TotemHNSWGraphRequest     hnsw_graph_request     = 15;
    TotemHNSWNodeRequest      hnsw_node_request      = 16;
    TotemHNSWNodeBatchRequest hnsw_node_batch_request = 17;
    TotemHNSWDeleteNodeRequest hnsw_delete_node_request = 18;
    // Responses (Totem → Seer)
    TotemSearchResponse        search_response         = 20;
    TotemIndexResponse         index_response          = 21;
    TotemRemoveResponse        remove_response         = 22;
    TotemLibraryResponse       library_response        = 23;
    TotemHNSWStatsResponse     hnsw_stats_response     = 24;
    TotemHNSWGraphResponse     hnsw_graph_response     = 25;
    TotemHNSWNodeResponse      hnsw_node_response      = 26;
    TotemHNSWNodeBatchResponse hnsw_node_batch_response = 27;
    TotemHNSWDeleteNodeResponse hnsw_delete_node_response = 28;
    // Control
    TotemPing ping = 30;
  }
}
```

---

## Totem Node Registry

`RegistryMutator` (actor in `Sources/Database/Mutators/RegistryMutator.swift`) tracks all connected Totem nodes:

```swift
// Registered nodes
var allNodes: [TotemNode]

// Only active (session open) nodes
var activeNodes: [TotemNode]

// Lookup by UUID
func totemNode(for id: UUID) async -> TotemNode?
```

`TotemNode` carries: `totemId`, `host`, `grpcPort`, `httpPort`, `lastSeen`, `isActive`, `acceptingStorage`.

`GET /v1/totems` exposes the full node list for debugging and client routing.

---

## Adding a New Fan-Out Operation

1. Add the request/response message pair to `totem.proto`.
2. Regenerate proto bindings (`protoc` with `grpc-swift` plugin).
3. Implement the RPC in Totem's `TotemQueryServiceImpl` (or the appropriate service impl).
4. Add the `TotemQueryClient` method in Seer's `Sources/GRPC/TotemQueryClient.swift`.
5. Add a `fanout*` method in `Seer+TotemFanout.swift`.
6. Wire the route in the appropriate `Sources/API/Routes/*.swift` file.

---

## Debugging

- `GET /v1/totems` — inspect registered nodes, activity, and storage acceptance state
- `POST /v1/admin/table/document` — fetches HNSW nodes for a document via `fanoutDocumentNodes`; useful for verifying index state without a graph visualization tool
- Totem nodes expose their own HTTP API for direct inspection (port configurable per node)
