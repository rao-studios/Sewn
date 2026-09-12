# Thread — Distributed Retrieval Integration

Thread is Sewn's retrieval backend. Each Thread node is an independently deployed
server holding documents, vectors, HNSW graphs, PQ codebooks, and a knowledge
graph. Sewn is the **mothership**: nodes dial in to it, and it fans every search,
index, remove, library, graph, and update request across the ones that are live.

**Sewn holds none of that data.** For the Thread implementation itself, see the
[Thread repository](https://github.com/riteshpakala/Totem).

---

## Who Owns What

The wire and the session machinery are **not** in this repository. They live in
the [Conduit](https://github.com/rao-studios/Conduit) package
(`.package(url: "https://github.com/rao-studios/Conduit.git", branch: "main")`).

| Type | Defined in |
|------|-----------|
| `ThreadNode` | Conduit — `Node/ThreadNode.swift` |
| `ThreadSessionManager` | Conduit — `Session/ThreadSessionManager.swift` |
| `ThreadQueryClient` | Conduit — `Client/ThreadQueryClient.swift` |
| `ThreadRegistrationServiceImpl` | Conduit — `Server/` |
| `ThreadRegistry` (protocol) | Conduit — `Protocols/` |
| `Thread_V1_*` generated messages | Conduit — `Generated/thread.pb.swift` |
| `thread.proto` | Conduit — `Protos/thread.proto` |
| `SewnGRPCServer`, `SewnConduitLogger` | **This repo** — `Sources/Conduit/` |
| `fanout*` primitives | **This repo** — `Sources/Core/Sewn+ThreadFanout.swift` |
| Node registry storage | **This repo** — `RegistryMutator` conforms to `ThreadRegistry` |

See `Skills/Conduit/README.md` for the transport layer.

---

## Registration & Session Lifecycle

Thread nodes connect to Sewn, not the reverse. Sewn listens on
`--grpc-port` (default **9091**).

```
Thread                               Sewn
  │                                   │
  │── Register(threadId, host, ───────►│  RegistryMutator.registerNode(_:)
  │      grpcPort, httpPort)          │  THREAD_HOST_OVERRIDE may rewrite host
  │◄───── RegisterResponse ────────────│  returns the mothership id
  │                                   │
  │── Session() ──────────────────────►│  bidirectional stream opens
  │◄── ThreadSessionMessage ───────────│  Sewn sends fan-out payloads
  │── ThreadSessionMessage ───────────►│  Thread replies; matched by correlation id
  │                                   │
  │── Heartbeat() ────────────────────►│  RegistryMutator.heartbeatNode(threadId:)
  │── UpdateAvailability(accepting) ──►│  RegistryMutator.updateNodeAvailability(…)
```

### Two different liveness clocks — don't confuse them

```swift
// Conduit — ThreadNode.swift
public var isActive: Bool { Date().timeIntervalSince(lastSeen) < 60 }
```

```swift
// This repo — RegistryMutator
let cutoff = Date().addingTimeInterval(-300)   // stale-entry purge
```

A node is **active** (and therefore a fan-out target) if it was seen within
**60 seconds**. Entries unseen for **300 seconds** are purged from the registry
entirely. A node can be inactive but still registered.

`threadNode(for:)` returns `nil` for an inactive node — a pinned request to a
quiet node fails rather than hanging.

### The ThreadRegistry seam

```swift
public protocol ThreadRegistry: Sendable {
    func registerNode(_ node: ThreadNode) async
    func heartbeatNode(threadId: UUID) async
    func updateNodeAvailability(threadId: UUID, accepting: Bool) async
}

// Sources/Core/Mutators/RegistryMutator.swift
extension RegistryMutator: ThreadRegistry {}
```

The conformance is empty — the actor's own methods are the witnesses. Conduit's
`ThreadRegistrationServiceImpl` writes through this protocol, which is why
registration state lands in the same actor that holds billing state.

---

## Fan-Out Primitives

All in `Sources/Core/Sewn+ThreadFanout.swift`, all `nonisolated`. **Route
handlers call these, never a gRPC client directly.**

| Method | Targets | Behavior |
|--------|---------|----------|
| `fanoutSearch(queryText:request:topK:)` | All active | Merge partition results; union the graph trace (entities deduped, expansion edges unioned) |
| `fanoutIndex(partitions:request:)` | **ONE** node | `request.threadIds` first match if active, else first node accepting storage. Returns `(success, threadId)` |
| `fanoutRemove(documentIds:ownerId:targetThreadIds:)` | All active, or the named ones | `targetThreadIds: nil` broadcasts |
| `fanoutLibrary(limit:afterId:threadIds:)` | All active, or named | `limit: nil` fetches every page; otherwise one page per node using `afterId` as cursor |
| `fanoutLibraryByDocuments(…)` | Targeted | Uses Thread's reverse `documentGroups` map — **no full library scan** |
| `fanoutGraph(…)` | All active | Entities dedupe by id (mention counts summed, max score); relationships dedupe by id (weights summed); documents dedupe by id; stats summed |
| `fanoutUpdateGroup(…)` | All active | Broadcast access/label/metadata change. True if **at least one** node confirms |
| `fanoutUpdateDocument(…)` | All active | Broadcast access/group change. True if at least one confirms |
| `fanoutStats()` | All active | Returns `[threadId: Thread_V1_ThreadStatsResponse]` |

### Search passes text, not vectors

```swift
var req = Thread_V1_ThreadSearchRequest()
req.queryText = queryText
req.queryEmbedding = []          // ← deliberately empty
req.queryEntityEmbedding = []    // ← deliberately empty
req.entities = request.entities ?? request.tags ?? []
req.ownerID = request.ownerId
req.scope = request.scope?.rawValue ?? "global"
req.topK = Int32(topK)
req.groupIds = (request.groups?.map(\.id) ?? []) + [request.group?.id].compactMap { $0 }
req.aggregate = request.aggregate ?? false
```

Each Thread embeds the text locally. That is why Sewn needs no embedding model on
the retrieval path, and why a mixed fleet can run different embedding models per
node without Sewn knowing.

### Failure semantics

Search fan-out runs in a `withTaskGroup` with `try?` per node. A node that
throws contributes nothing and is logged; the surviving nodes' results are still
merged. **A dead node degrades recall, it does not fail the turn.**

Index is the opposite — it has one target, so a failure there means the document
is not stored. Backpressure is retried three times with jittered backoff
(500 ms / 1 s / 2 s) before the batch is dropped with a warning.

---

## Why Index Is Not Broadcast

A document's vectors and graph edges must be co-located to be searchable, so a
document lives on exactly **one** node. Sewn records the affinity:

```swift
func recordOwnerThread(ownerId: String, threadId: UUID)
func threadNodesForOwner(_ ownerId: String, allNodes: [ThreadNode]) -> [ThreadNode]
```

`threadNodesForOwner` falls back to all nodes when the owner is unknown, so a
restart that loses the in-memory affinity map degrades to broadcast rather than
to silence. Broadcasting **search** is what makes the fleet look like one corpus.

---

## gRPC Services (`thread.proto`)

| Service | RPCs |
|---------|------|
| `ThreadRegistration` | `Register`, `Heartbeat`, `UpdateAvailability`, `Session` (bidi stream) |
| `ThreadQuery` | `Search`, `Index`, `Remove` |
| `ThreadUpdate` | `UpdateGroup`, `UpdateDocument`, `Stats` |
| `ThreadLibrary` | `Library`, `Documents`, `ExportCorpus` |
| `ThreadGraph` | `Query` |

`ThreadQueryClient` exposes one method per RPC, each taking a `ThreadNode`:

```swift
func search / index / remove / library / documents / graph
   / updateGroup / updateDocument / stats
```

### Session envelope

`Session` is a bidirectional stream of `ThreadSessionMessage`, whose `oneof
payload` carries request/response pairs matched by correlation id:

```protobuf
message ThreadSessionMessage {
  // correlation id + thread id
  oneof payload {
    ThreadSessionPing            ping                     = 3;
    ThreadSessionPong            pong                     = 4;
    ThreadSearchRequest          search_request           = 5;
    ThreadSearchResponse         search_response          = 6;
    ThreadIndexRequest           index_request            = 7;
    ThreadIndexResponse          index_response           = 8;
    ThreadRemoveRequest          remove_request           = 9;
    ThreadRemoveResponse         remove_response          = 10;
    ThreadLibraryRequest         library_request          = 11;
    ThreadLibraryResponse        library_response         = 12;
    ThreadUpdateGroupRequest     update_group_request     = 23;
    ThreadUpdateGroupResponse    update_group_response    = 24;
    ThreadUpdateDocumentRequest  update_document_request  = 25;
    ThreadUpdateDocumentResponse update_document_response = 26;
    ThreadStatsRequest           stats_request            = 27;
    ThreadStatsResponse          stats_response           = 28;
    ThreadGraphQueryRequest      graph_request            = 29;
    ThreadGraphQueryResponse     graph_response           = 30;
    ThreadDocumentsRequest       documents_request        = 31;
    ThreadDocumentsResponse      documents_response       = 32;
  }
}
```

**Field numbers are the wire.** Never renumber or reuse one.

---

## Routes Backed by Thread

| Route | Fan-out used |
|-------|-------------|
| `POST /v1/search` | `fanoutSearch` |
| `POST /v1/chat/completions`, `/v1/realtime/chat` | `fanoutSearch` (+ compaction) |
| `POST /v1/embeddings` | `fanoutIndex` (one node) |
| `POST /v1/graph` | `fanoutGraph` |
| `GET /v1/stats` | `fanoutStats` |
| `POST /v1/list/documents`, `/v1/list/groups` | `fanoutLibrary` |
| `POST /v1/list/groups/documents` | `fanoutLibraryByDocuments` |
| `POST /v1/modify` | `fanoutUpdateDocument` / `fanoutRemove` |
| `POST /v1/modify/group/access`, `/metadata` | `fanoutUpdateGroup` |
| `POST /v1/modify/group/remove` | `fanoutRemove` |
| `GET /v1/infinite/leaderboard`, `POST /v1/infinite/search` | `fanoutLibrary` + local billing stats |
| `GET /v1/threads` | The registry directly — node list, activity, storage acceptance |

---

## Adding a New Fan-Out Operation

1. Add the request/response message pair to `thread.proto` **in Conduit**, with
   fresh field numbers.
2. Add the pair to the `ThreadSessionMessage` `oneof` if it should travel over the
   session stream.
3. Regenerate the bindings in Conduit (`protoc` with the grpc-swift plugin).
4. Implement the RPC on the Thread side.
5. Add the client method to Conduit's `ThreadQueryClient`.
6. Add a `fanout*` method in `Sources/Core/Sewn+ThreadFanout.swift`, choosing
   broadcast-and-merge or single-target deliberately.
7. Wire the route in `Sources/API/Routes/`.

---

## Debugging

- `GET /v1/threads` — registered nodes, `is_active`, `accepting_storage`,
  `last_seen`. First stop for "why did my search return nothing".
- `GET /v1/stats` — aggregate public document and group counts across the fleet.
- `POST /v1/graph` — inspect entity resolution and traversal without a
  visualization tool.
- `THREAD_HOST_OVERRIDE` — set when a node advertises an address Sewn cannot
  route to.
- Conduit logs route through `SewnConduitLogger`, so session and client lines
  appear in the same structured stream under `service: "Sewn"`.

**No Thread connected** is a distinct failure mode worth recognizing:
`_threadQueryClient` is `nil`, `fanoutSearch` returns `([], nil)`, searches come
back empty, and `_removeAll` logs `"no Thread connected — vectors not removed"`.
Nothing errors.

---

## Where the Vector Code Went

`PartitionTable`, `PartitionIndex`, `PartitionQuantizer`, `PartitionSlot`,
`HNSWGraph`, `HNSWVectorStore`, `HNSWTopologyWAL`, `TableMutator`,
`PersonalHNSWMutator`, per-owner personal graphs, and the adaptive PQ threshold
all moved to the Thread repository during the distributed rewrite.

Alongside them went the routes that exposed them: every `/v1/hnsw/*` endpoint and
every `/v1/admin/hnsw/*` endpoint. What replaced them is narrower and honest —
`POST /v1/graph` for knowledge-graph queries and `GET /v1/stats` for aggregate
counts. Compaction, dedup, and rebuild are triggered on Thread nodes directly
through their own HTTP API.
