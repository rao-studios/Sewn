# Test Maintenance

How the Sewn test suite is organized, and how to add to it.

**Framework: XCTest**, `@testable import sewn_server` (module name is
`sewn_server`, with an underscore). Web-layer tests use `HummingbirdTesting` and
`HummingbirdWSTesting`, both declared on the test target in `Package.swift`.
There is no `XCTVapor` — that dependency is gone.

```bash
swift test
swift test --filter Flow2_GitaRoyaltyTests
swift test --filter testEmptyPartitionsReturnsEmptyContribution
```

---

## Layout

```
Tests/sewn-serverTests/
├── Helpers/Fixtures.swift        — every factory and test double
│
├── Flow1_DocumentCIDTests        — content hashing / document identity
├── Flow1_TagGeneratorTests       — tag extraction
├── Flow1_TextChunkerTests        — 1500-char chunking, boundary preference
│
├── Flow2_GitaCreditTests         — credit math
├── Flow2_GitaRoyaltyTests        — word-count shares, multi-owner, determinism
├── Flow2_GitaSpanTests           — n-gram heuristic spans
├── Flow2_GitaWalletTests         — wallet ops, derived totals
│
├── Flow3_SinatraTests            — the prepare loop
├── Flow3_SinatraGBTTests         — training and prediction
├── Flow3_SinatraMemoryBoundTests — the 30-entry parked cap
├── Flow3_SinatraParkAlignmentTests — park/label alignment across turns
├── Flow3_SinatraResetTests       — reset clears everything
├── Flow3_SinatraExportImportTests — round-trip state
│
├── Flow4_DocumentStatsTests      — billing stat accumulation
├── Flow4_RegistryWALTests        — WAL append, checkpoint, replay
│
├── Flow5_OwnerIdNormalizationTests — lowercase owner ids
│
├── Flow6_AutoMemoryTests         — triggers and policy modes
├── Flow6_QueryExpansionTests     — expandQuery (currently original-only)
│
├── ChatPersonaTests              — persona resolution
├── CodeCompleteTests             — /v1/code/complete
├── CompleteTests                 — /v1/complete
├── SkillsCompleteTests           — /v1/skills/complete, tool_calls
├── DataDirectoryTests            — --data-dir / SEWN_DATA_DIR resolution
├── LLMProviderTests              — the enum, serverDefault, localUtilityEnabled
├── ProviderRoutingTests          — resolution, family rejection, 400/503
├── MarkerSpanTests               — [[n]] parsing, stripping, offsets
├── RealtimeTests                 — the turn engine, offline via Deps
├── RequestResponseTests          — wire shapes
├── SentenceBoundaryTests         — sentence splitting
├── TextCompletionParametersTests — parameter precedence, token budgets
├── UtilsTests / SimpleTests      — helpers and sanity
└── VisionLookTests               — /v1/vision/look
```

### The Flow convention

`FlowN_` groups tests by the user-facing journey they protect, not by source
file:

| Flow | Journey |
|------|---------|
| **Flow1** | Ingest — identity, chunking, tagging |
| **Flow2** | Money — Gita royalty, credits, spans, wallet |
| **Flow3** | Learning — Sinatra in all its parts |
| **Flow4** | Billing state — document stats, registry WAL |
| **Flow5** | Identity normalization |
| **Flow6** | Conversation memory — auto-memory, query expansion |

Numbers are not contiguous, and old ones are **retired, not reused**. Flows 7–11
and 16–17 covered orphan cleanup, the IndexQueue actor, vector persistence,
indices splitting, and deletion cleanup — all for code that moved to Thread.
Flow12 (Oracle) and Flow13 (Marielle) were reserved and never written; Oracle is
gone, Marielle is still unimplemented.

**Add to an existing flow when the journey matches.** Start a new number only for
a genuinely new journey, and record it in the table above.

Route-level and unit tests that do not map to a journey use a plain descriptive
name (`ProviderRoutingTests`, `MarkerSpanTests`).

---

## Fixtures

`Helpers/Fixtures.swift` is the only place test data is constructed. Everything
follows one convention: **a `.test` static, or a `test(…)` factory with
defaults.**

```swift
func wipeSewnPersistenceFiles()            // clean the data dir between tests

extension Logger        { static var test: Logger }
extension SewnLogger    { static var test: SewnLogger }
extension RegistryMutator { static func test() -> RegistryMutator }

extension Sewn.Partition   { static func test(id:documentId:text:ownerId:…) -> Self }
extension Sewn.Document    { static func test(…) -> Self }
extension Sewn.Group       { static func test(…) -> Self }
extension SewnRequest      { static func test(…) -> Self }
extension Gita.TokenLedger { static var twoCall: Gita.TokenLedger }
```

### Embeddings

```swift
enum <Embeddings fixture> {
    static let dim = 32                                  // NOT production dimensionality
    static func zeros() -> [Float]
    static func unit(axis: Int) -> [Float]
    static func random(seed: UInt64) -> [Float]
    static func random(dim: Int, seed: UInt64) -> [Float]
    static func near(_ center: [Float], seed: UInt64) -> [Float]
    static func l2(_ a: [Float], _ b: [Float]) -> Float
}
```

**Seeded, not random.** `random(seed:)` is deterministic, so a failure is
reproducible. Never use `Float.random(in:)` in a test.

### Test doubles

A model-provider double implements the concurrency-slot protocol as no-ops:

```swift
func acquirePreprocessSlot() async {}
func releasePreprocessSlot() async {}
func run(…) -> /* a scripted response */
```

That is how tests exercise generation paths with no network.

---

## Writing a Test

### Unit test over a pure component

```swift
import XCTest
@testable import sewn_server

final class Flow2_GitaRoyaltyTests: XCTestCase {

    private var gita: Gita!

    override func setUp() {
        super.setUp()
        gita = Gita(logger: .test)
    }

    // MARK: - Edge cases

    func testEmptyPartitionsReturnsEmptyContribution() {
        let contribution = gita.royalty(for: [])
        XCTAssertTrue(contribution.owners.isEmpty)
    }

    // MARK: - Single owner
    // …
}
```

House style: a file-header comment listing what the file covers, `// MARK:`
sections grouping cases, private helpers that wrap the fixture factories, and
`setUp` constructing a fresh subject with `.test` loggers.

### Actor test

```swift
final class RegistryMutatorTests: XCTestCase {

    override func setUp() async throws {
        wipeSewnPersistenceFiles()
    }

    func test_concurrentAccumulation_doesNotLoseWrites() async {
        let mutator = RegistryMutator.test()

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask { await mutator.accumulateEarnings(["doc-\(i)": 1.0]) }
            }
        }

        let stats = mutator.snapshot?.documentStats ?? [:]
        XCTAssertEqual(stats.count, 100)
    }
}
```

**`wipeSewnPersistenceFiles()` in `setUp` is mandatory** for anything that
persists. Tests share one data directory; a leftover `registry` or `registry-wal`
from a previous test will be loaded and will fail the next one in confusing ways.

### Realtime / turn-engine test

The engine takes all provider work as closures, so drive it entirely offline:

```swift
let engine = RealtimeTurnEngine(
    deps: .init(
        opening:   { _ in scriptedStream(["Hi ", "there"]) },
        retrieval: { ChatResult(input: .init(messages: []), references: []) },
        grounded:  { _ in scriptedStream(["— about ", "HNSW[[1]]"]) },
        tts:       { _ in scriptedPCM() }
    ),
    openingSystemPrompt: "",
    historyMessages: [["role": "user", "content": "hello"]],
    logger: .test
)

var frames: [RealtimeOutbound] = []
let summary = try await engine.run { frames.append($0) }
```

Assert on the **frame sequence**, not just the final text — ordering is the
contract.

### Route test

```swift
let app = /* build the router as configureRoutes does */
try await app.test(.router) { client in
    try await client.execute(uri: "/health", method: .get) { response in
        XCTAssertEqual(response.status, .ok)
    }
}
```

Note that `/health` is registered as `"health"` without a leading slash.

---

## Rules

1. **`wipeSewnPersistenceFiles()` in `setUp`** for anything touching disk.
2. **Seeded embeddings only.** Determinism over realism.
3. **Fixtures go in `Fixtures.swift`**, never inline in a test file.
4. **No network.** Inject a double. If a path cannot be tested without the
   network, that path needs a seam.
5. **Test the gates.** Sinatra's word-count and resonance-confidence gates,
   Gita's empty-partition and zero-word guards, provider family rejection — these
   are where behavior actually lives.
6. **Lowercase owner ids** in fixtures, matching `SewnRequest.from(_:)`.
7. **Assert invariants, not just values.** `owners.earning.sum + serviceCharge ==
   totalCost`; `influence` sums to 1 per owner; `royalty` sums to 1 across
   owners.
8. **Marker offsets are into stripped text.** A span test that passes against raw
   text is testing the wrong thing.

---

## Coverage Gaps

| Area | State |
|------|-------|
| Marielle | **None.** Flow13 reserved, never written. Routes 503 |
| Thread fan-out | No integration test — needs a Conduit-level double for `ThreadQueryClient` |
| Conduit session / gRPC | Not covered here; belongs to Conduit |
| Admin routes | Not covered. Several are stubs anyway |
| Infinite leaderboard | Scoring and normalization untested |
| Graph proxy | `fanoutGraph` merge rules (sum vs max) untested |
| IMBHS | `HarmonyMemory` improvisation, PAR/BW schedules, fitness gating untested |
| Stream billing | Mid-stream disconnect billing untested |

The highest-value gap is a **`ThreadQueryClient` double**. It would unlock
fan-out merge semantics, partial-failure degradation, index placement, and the
graph merge rules — the behaviors most likely to regress, and currently the least
covered.

---

## When You Change Something

| Change | Test to add or update |
|--------|----------------------|
| Royalty math | `Flow2_GitaRoyaltyTests` + the invariant assertions |
| Span tiers | `Flow2_GitaSpanTests`, `MarkerSpanTests` |
| A Sinatra gate | `Flow3_Sinatra*` — assert the gate *blocks*, not just that it passes |
| A `SinatraRegistry` field | `Flow3_SinatraExportImportTests` round-trip |
| A billing field | `Flow4_DocumentStatsTests` **and** `Flow4_RegistryWALTests` replay |
| Parameter precedence | `TextCompletionParametersTests` |
| Provider resolution | `ProviderRoutingTests`, `LLMProviderTests` |
| A realtime frame | `RealtimeTests` — assert sequence |
| Chunking or tagging | `Flow1_TextChunkerTests`, `Flow1_TagGeneratorTests` |
| Anything keyed by owner id | `Flow5_OwnerIdNormalizationTests` |
