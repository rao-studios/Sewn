# Thread — Distributed Vector Search Integration

Thread is Sewn's vector search backend. Each Thread node is an independently deployed Swift server that holds HNSW graphs, PQ codebooks, and document partition data. Sewn connects to Thread nodes as a **mothership**: it fans out all search, index, remove, and library requests across all registered nodes.

For the full Thread implementation, see the [Thread repository](https://github.com/riteshpakala/Totem).

---

## Registration & Session Lifecycle

Thread nodes connect to Sewn (not the other way around). Sewn listens on **port 9091** (gRPC) via `MothershipRegistrationService`.

```
Thread                          Sewn
  │                              │
  │── register() ───────────────►│  sends threadId, host, grpcPort, httpPort
  │                              │  Sewn stores node in RegistryMutator
  │                              │
  │── session() ────────────────►│  opens bidirectional stream
  │◄── ThreadSessionMessage ──────│  Sewn sends fan-out request payloads
  │── ThreadSessionMessage ──────►│  Thread replies with results
  │   (ping every 30s)           │  Sewn matches reply by correlationID
  │                              │
  │── updateAvailability() ─────►│  Thread signals acceptingStorage true/false
```

A Thread node is considered **active** while its session stream is open. Sewn marks it inactive when the stream closes or times out. Only active nodes receive fan-out.

---

## Fan-Out Primitives

All fan-out is in `Sources/GRPC/Sewn+ThreadFanout.swift`:

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

## gRPC Services on Thread

Thread exposes three gRPC services, reachable both directly and via the session stream:

| Service | RPCs |
|---------|------|
| `ThreadQuery` | `search`, `index`, `remove`, `library` |
| `ThreadLibrary` | `library` (paginated group listing) |
| `ThreadHNSW` | `stats`, `graph`, `node`, `nodeBatch`, `deleteNode` |

The session stream wraps these as `ThreadSessionMessage` payloads with a `correlationID` for matching replies.

---

## Session Message Envelope

```protobuf
message ThreadSessionMessage {
  string correlation_id = 1;
  string thread_id       = 2;
  oneof payload {
    // Requests (Sewn → Thread)
    ThreadSearchRequest        search_request         = 10;
    ThreadIndexRequest         index_request          = 11;
    ThreadRemoveRequest        remove_request         = 12;
    ThreadLibraryRequest       library_request        = 13;
    ThreadHNSWStatsRequest     hnsw_stats_request     = 14;
    ThreadHNSWGraphRequest     hnsw_graph_request     = 15;
    ThreadHNSWNodeRequest      hnsw_node_request      = 16;
    ThreadHNSWNodeBatchRequest hnsw_node_batch_request = 17;
    ThreadHNSWDeleteNodeRequest hnsw_delete_node_request = 18;
    // Responses (Thread → Sewn)
    ThreadSearchResponse        search_response         = 20;
    ThreadIndexResponse         index_response          = 21;
    ThreadRemoveResponse        remove_response         = 22;
    ThreadLibraryResponse       library_response        = 23;
    ThreadHNSWStatsResponse     hnsw_stats_response     = 24;
    ThreadHNSWGraphResponse     hnsw_graph_response     = 25;
    ThreadHNSWNodeResponse      hnsw_node_response      = 26;
    ThreadHNSWNodeBatchResponse hnsw_node_batch_response = 27;
    ThreadHNSWDeleteNodeResponse hnsw_delete_node_response = 28;
    // Control
    ThreadPing ping = 30;
  }
}
```

---

## Thread Node Registry

`RegistryMutator` (actor in `Sources/Database/Mutators/RegistryMutator.swift`) tracks all connected Thread nodes:

```swift
// Registered nodes
var allNodes: [ThreadNode]

// Only active (session open) nodes
var activeNodes: [ThreadNode]

// Lookup by UUID
func threadNode(for id: UUID) async -> ThreadNode?
```

`ThreadNode` carries: `threadId`, `host`, `grpcPort`, `httpPort`, `lastSeen`, `isActive`, `acceptingStorage`.

`GET /v1/threads` exposes the full node list for debugging and client routing.

---

## Adding a New Fan-Out Operation

1. Add the request/response message pair to `thread.proto`.
2. Regenerate proto bindings (`protoc` with `grpc-swift` plugin).
3. Implement the RPC in Thread's `ThreadQueryServiceImpl` (or the appropriate service impl).
4. Add the `ThreadQueryClient` method in Sewn's `Sources/GRPC/ThreadQueryClient.swift`.
5. Add a `fanout*` method in `Sewn+ThreadFanout.swift`.
6. Wire the route in the appropriate `Sources/API/Routes/*.swift` file.

---

## Debugging

- `GET /v1/threads` — inspect registered nodes, activity, and storage acceptance state
- `POST /v1/admin/table/document` — fetches HNSW nodes for a document via `fanoutDocumentNodes`; useful for verifying index state without a graph visualization tool
- Thread nodes expose their own HTTP API for direct inspection (port configurable per node)
