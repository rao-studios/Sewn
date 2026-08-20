# Test Maintenance

Guide to writing, organizing, and maintaining tests for Seer. The existing test suite follows a "Flow" convention — each flow represents a user journey or system behavior.

---

## Test Organization

```
Tests/seer-serverTests/
├── FlowN_*.swift          — Feature flow tests (numbered 1–11, grow from here)
├── SimpleTests.swift      — Basic sanity checks
├── UtilsTests.swift       — Utility function tests
├── SentenceBoundaryTests.swift
├── TextCompletionParametersTests.swift
├── RequestResponseTests.swift
├── RegistryOwnershipTests.swift
└── Fixtures.swift         — Shared test data factories
```

### Flow Numbering Convention

| Flow | Coverage |
|------|---------|
| Flow1 | Document embedding, upload, CID |
| Flow2 | Sinatra (GBT, resonance, park alignment, reset), Gita (credits, royalty, spans, wallet), document stats |
| Flow3 | HNSW invariants, partition index, quantizer, HNSW search predicates, **GlobalPartitionTable** (two-tier search, tag filter, slot resolution, Sinatra side effects) |
| Flow4 | Adaptive threshold |
| Flow5 | Batch indexing |
| Flow6 | Query expansion, auto-memory |
| Flow7 | Orphan cleanup |
| Flow8 | IndexQueue |
| Flow9 | Vector persistence |
| Flow10 | Owner ID normalization |
| Flow11 | Indices split |
| Flow16 | Deletion cleanup (`PartitionData` file written/purged on put/remove) |
| Flow17 | Sinatra memory bounds |
| **Flow12** | **Oracle P2P (to be written)** |
| **Flow13** | **Marielle personalization (to be written)** |

---

## Test Template: New Flow Test

```swift
// Tests/seer-serverTests/Flow12_OracleTests.swift
import XCTest
@testable import SeerServer

final class Flow12_OracleTests: XCTestCase {
    
    var seer: Seer!
    var oracle: Oracle!
    
    override func setUp() async throws {
        // Use in-memory persistence (no disk I/O in tests)
        seer = await Seer(persistence: .inMemory)
        oracle = Oracle(transport: MockOracleTransport(), delegate: seer)
    }
    
    override func tearDown() async throws {
        // Clean up actor state
        await seer.reset()
    }
    
    func test_queryFanOut_respectsHopLimit() async throws {
        // Arrange
        let query = OracleQueryRequest(
            query_id: "test-q-1",
            embedding: Fixtures.embedding(dimensions: 1024),
            owner_id: "owner-a",
            scope: .global,
            hop_limit: 0,       // Should NOT fan out
            visited_nodes: [],
            top_k: 5,
            threshold: 0.7
        )
        
        // Act
        let response = try await oracle.handleQuery(query)
        
        // Assert
        XCTAssertEqual(response.results.count, 0)  // hop_limit = 0, no local docs
    }
    
    func test_visitedNodes_preventsCycles() async throws {
        // Arrange: pre-populate visited_nodes with local node ID
        let localNodeId = await oracle.nodeId
        let query = OracleQueryRequest(
            query_id: "test-q-2",
            embedding: Fixtures.embedding(dimensions: 1024),
            owner_id: "owner-a",
            scope: .global,
            hop_limit: 3,
            visited_nodes: [localNodeId],  // Already visited this node
            top_k: 5,
            threshold: 0.7
        )
        
        // Act
        let response = try await oracle.handleQuery(query)
        
        // Assert: returns early without processing
        XCTAssertTrue(response.results.isEmpty)
    }
}
```

---

## Test Template: Actor Unit Test

```swift
// Tests/seer-serverTests/SomeActorTests.swift
import XCTest
@testable import SeerServer

final class SomeActorTests: XCTestCase {
    
    func test_registryMutator_serializesWrites() async throws {
        let mutator = RegistryMutator()
        var registry = SeerRegistry()
        
        // Concurrent writes — should not race
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    await mutator.addDocument(
                        id: "doc-\(i)",
                        owner: SeerRegistry.Owner(id: "owner-1"),
                        to: &registry
                    )
                }
            }
        }
        
        XCTAssertEqual(registry.owners_documents["owner-1"]?.count, 100)
    }
}
```

---

## Test Template: Route Integration Test

```swift
// Tests/seer-serverTests/RouteTests.swift
import XCTest
import XCTVapor
@testable import SeerServer

final class WalletRouteTests: XCTestCase {
    
    var app: Application!
    
    override func setUp() async throws {
        app = try await Application.testable()  // Uses test fixtures
    }
    
    override func tearDown() async throws {
        app.shutdown()
    }
    
    func test_wallet_returnsBalance() async throws {
        // Arrange: index a document and run an inference to generate earnings
        let ownerId = "test-owner-wallet"
        try await Fixtures.indexDocument(app: app, ownerId: ownerId)
        try await Fixtures.runInference(app: app, ownerId: ownerId)
        
        // Act
        try app.test(.GET, "/v1/wallet", headers: [
            "Authorization": "Bearer \(Fixtures.validToken(ownerId: ownerId))"
        ]) { response in
            // Assert
            XCTAssertEqual(response.status, .ok)
            let wallet = try response.content.decode(WalletResponse.self)
            XCTAssertGreaterThan(wallet.total_earned, 0)
        }
    }
}
```

---

## Fixtures (`Fixtures.swift`)

The `Fixtures.swift` file provides reusable test data. Always extend it rather than hardcoding values in individual tests.

**Actual helpers** (in `Fixtures.swift`):
- `SeerLogger.test` / `Logger.test` — silent logger for tests
- `TableMutator.test()` — in-memory mutator seeded with empty table
- `RegistryMutator.test()` — mutator seeded with empty registry
- `SeerRequest.test(ownerId:scope:)` — minimal request fixture
- `Seer.Document.test(id:ownerId:)` — document with example URL
- `Seer.Partition.test(id:documentId:embedding:text:hint:ownerId:)` — partition with all fields
- `VectorFixtures.random(seed:)` / `.random(dim:seed:)` — deterministic 32-dim or N-dim vector
- `VectorFixtures.near(_:seed:)` — perturbed copy (small noise) of a center vector
- `VectorFixtures.unit(axis:)` — unit vector along one axis (32-dim)
- `VectorFixtures.l2(_:_:)` — L2 distance between two vectors

**Add new helpers when**:
- 3+ tests need the same setup
- The setup involves actor initialization with test-safe persistence

---

## Writing Tests for New Features

### Step 1: Identify the flow number

If the feature fits an existing flow (e.g. new Gita behavior → Flow2), add to that file. If it's a new system area, create `FlowN+1_*.swift`.

### Step 2: Test the happy path first

```swift
func test_feature_happyPath() async throws {
    // Arrange: minimal setup
    // Act: call the thing
    // Assert: verify the expected output
}
```

### Step 3: Test failure modes

```swift
func test_feature_returnsErrorWhenInputInvalid() async throws { ... }
func test_feature_gracefullyDegrades_whenDependencyFails() async throws { ... }
```

### Step 4: Test actor safety if touching mutators

For any test that exercises `TableMutator`, `RegistryMutator`, or `PersonalHNSWMutator`, add a concurrent write test to prove serialization holds.

### Step 5: Test persistence round-trip for new registry fields

```swift
func test_newField_persistsAndLoads() async throws {
    let seer = await Seer(persistence: .tempDirectory)
    await seer.setSomeNewField("value", for: "owner-1")
    
    // Simulate restart
    let reloaded = await Seer(persistence: .tempDirectory)
    let value = await reloaded.someNewField(for: "owner-1")
    XCTAssertEqual(value, "value")
}
```

---

## Tests Still Needed (Gap Analysis)

| Area | Missing Test | Priority |
|------|-------------|---------|
| Oracle | Query fan-out, cycle prevention, hop limit, gossip | High |
| Marielle | Open question confidence, proactive scoring, bridge with bridging disabled | High |
| Chat | Sinatra tone override actually changes generation params | High |
| Gita | `non_self_earnings` cross-owner tracking | Medium |
| Gita | Peer results in payload (when Oracle enabled) | Medium |
| Storage | Restore re-indexes correctly (node count before/after) | Medium |
| Auth | Token expiry handling, refresh token rotation | Medium |
| Admin | `audit/stale` + `audit/reconcile` round-trip | Low |
| Seer | `Seer+Marielle.bridge` centroid intersection math | Low |

Create `Flow12_OracleTests.swift` and `Flow13_MarielleTests.swift` next.

---

## Writing Tests for `GlobalPartitionTable`

When testing two-tier search behavior:

1. Create a `GlobalPartitionTable` with a `HNSWVectorStore` attached (use `HNSWVectorStore.vectorDim` for vector dimensions — this is what the HNSW uses internally)
2. Insert partitions via `table.add(partition:)` — this stores the embedding in the mmap'd vector store
3. Build `PartitionIndex` entries by calling `index.train([partition], tags:tagsEmbedding:documentId:logger:)` with the same partition objects (PQ training consumes the embedding; the graph already has it stored separately)
4. Use `PropertyListEncoder`/`PropertyListDecoder` for Codable round-trip tests (not `JSONEncoder` — `effectiveThreshold` starts as `Float.infinity` which JSON can't encode)
5. Tag filter correctness: orthogonal unit vectors (`unit(axis: 0)` vs `unit(axis: 1)`) produce `tagDistance = 1.0`, which exceeds the default threshold (0.85) → excluded; identical vectors produce `tagDistance = 0.0` → always included
6. Sinatra side effects: check `sinatra.registry?.parkedIndices[ownerKey]` after `search()` to verify `parkIndices` was called for documents with `tagsEmbedding != nil`

---

## Running Tests

```bash
# All tests
swift test

# Specific flow
swift test --filter Flow2

# With verbose output
swift test --verbose

# Parallel (default in Swift 5.10+)
swift test --parallel
```

---

## Test Stability Rules

1. **No real disk I/O**: use `.inMemory` or `.tempDirectory` persistence, never `~/.seer/`
2. **No real network**: use `MockOracleTransport` and mock `NetworkService`
3. **No real Supabase**: mock `SupabaseProvider` for auth in route tests
4. **No sleep**: use `async/await` properly; if something needs time, it needs a redesign
5. **Deterministic**: tests must pass in any order, in any OS thread scheduler state
6. **No shared mutable state between tests**: each test gets a fresh actor instance in `setUp`
