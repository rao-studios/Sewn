# HNSW — Graph Proxy Layer

> HNSW graphs no longer live in Sewn. All HNSW data (nodes, vectors, codebooks) is owned and managed by **Thread nodes**. Sewn's role is to proxy HNSW requests to the appropriate Thread node via gRPC.

For the HNSW implementation itself, see [Thread/README.md](../Thread/README.md) or the Thread repository.

---

## Sewn's HNSW Role

[HNSW.swift](../../Sources/API/Routes/HNSW.swift) registers all `/v1/hnsw/*` routes as thin gRPC adapters:

**Stats routes** — fan out to **all** active Thread nodes, aggregate results:
- `POST /v1/hnsw/stats` — sum live nodes across nodes, max level
- `POST /v1/hnsw/document/stats` — same, filtered to one document

**Graph routes** — proxy to a **specific** Thread node via `sewn.thread_ids[0]`:
- `POST /v1/hnsw/personal` — personal graph (scope: personal)
- `POST /v1/hnsw/personal/hubs` — hub-only personal graph
- `POST /v1/hnsw/personal/document` — personal graph for one document
- `POST /v1/hnsw/personal/documents` — personal graph for a set of documents
- `POST /v1/hnsw/global` — global graph
- `POST /v1/hnsw/global/hubs` — hub-only global graph
- `POST /v1/hnsw/documents` — global graph for a set of documents
- `POST /v1/hnsw/documents/hubs` — hub-only global graph for a document set
- `POST /v1/hnsw/node` — single node inspection
- `POST /v1/hnsw/nodes/batch` — batch node fetch
- `DELETE /v1/hnsw/node` — soft-delete a node

---

## Routing Helpers

```swift
// Resolve the target Thread node from sewn.thread_ids[0]
private func targetNode(_ sewnRequest: SewnRequest, sewn: Sewn) async throws -> (ThreadQueryClient, ThreadNode)

// Fan out stats to ALL active Thread nodes
private func fanoutStats(sewn: Sewn, statReq: Thread_V1_ThreadHNSWStatsRequest) async throws -> HNSWStatsResponse
```

`targetNode` throws `400 Bad Request` if `thread_ids` is missing or the UUID doesn't match a registered node. Always include `thread_ids` in graph route requests.

---

## Admin HNSW Routes

All admin HNSW routes (`/v1/admin/hnsw/*`) return `503 Service Unavailable` with reason "HNSW is managed by Thread nodes". Compact, dedup, and rebuild operations must be triggered directly on Thread nodes via their HTTP API.

---

## Adding an HNSW Feature

1. Add the RPC to the Thread proto (`Thread_V1_ThreadHNSWService`) in the shared proto file.
2. Implement it in Thread's `ThreadHNSWServiceImpl`.
3. Add the gRPC call to `ThreadQueryClient` in Sewn's `Sources/GRPC/`.
4. Register the route in `HNSW.swift` using `targetNode()` or `fanoutStats()`.
