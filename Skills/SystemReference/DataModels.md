# Data Models Reference

Every Swift type that crosses a boundary — persisted, sent on the wire, or shared
between subsystems. Grouped by owning namespace.

Conventions throughout:
- **`CodingKeys` are snake_case** on the wire, camelCase in Swift.
- **Tolerant decoders.** Most persisted types use `decodeIfPresent` with defaults
  so an older on-disk file still loads. Follow this when adding a field.
- **Owner ids are lowercased** at the boundary (`SewnRequest.from(_:)`).
  Supabase `auth.uid()` is lowercase; `UUID.uuidString` is uppercase.
- `FilePersistence` writes **property lists**, not JSON. Non-finite `Double`s
  cannot be encoded.

---

## Core — `Sources/Core/Models/`

### Aliases

```swift
typealias DocumentID = String
typealias GroupID    = String
typealias OwnerID    = String
typealias OracleNodeID = UUID     // in Gita.Contribution.swift — vestigial, see below
```

### SewnRegistry

```swift
/// Lean billing-only registry. Document/group/ownership data lives on Thread nodes.
struct SewnRegistry: Codable {
    var documentStats: [DocumentID: Sewn.DocumentStats] = [:]
    var bridgingEnabledOwners: Set<OwnerID> = []
}
```

Two fields. That is the whole registry. Its decoder ignores every legacy field
(`ownersDocuments`, groups, access maps) so pre-split files decode without
crashing.

```swift
enum Access: String, Codable { case available, restricted, unknown }
struct Owner: Codable, Hashable { let id: OwnerID }
```

`Owner` is the key type for every Sinatra per-owner map.

### Sewn.Document

```swift
struct Document: Codable {
    var id: String
    var url: URL
    var ownerId: String        // "owner_id"
    var createdAt: Date = .now // "created_at"
}

struct DocumentReference: Codable {
    var id: String
    var partitionId: String    // "partition_id"
    var ownerId: String        // "owner_id"
    var threadId: String? = nil  // "thread_id"  — which node served it
    var shardIndex: Int? = nil   // "shard_index"
}
```

`DocumentReference` is what a chat response returns in `references`. `threadId`
is how a client can trace a citation back to the node that produced it.

### Sewn.Partition

```swift
enum MediaType: String, Codable { case text, image /* … */ }

struct Partition: Codable {
    let id: String
    let documentId: String              // "document_id"
    var url: URL
    var embedding: [Float]
    var compressedEmbedding: [UInt16]?  // "compressed_embedding" — PQ codes from Thread
    var mediaType: MediaType = .text    // "media_type"
    var text: String
    var ownerId: String                 // "owner_id" — EMPTY means unauthenticated Thread
    var metadata: Data?                 // opaque, passed through
}
```

Three things to know:

- **`ownerId` may be an empty string.** Gita treats that as `nil` and attributes
  the partition to its `threadId` instead. Never assume it is populated.
- `text` is what Gita counts words from — the royalty share's entire basis.
- `compressedEmbedding` is Thread's PQ code, carried for Sinatra's feature
  vector, not for search.

### Sewn.Group

```swift
struct Group: Codable {
    var id: String
    var label: String
    var ownerId: String                 // "owner_id"
    var documents: [Sewn.Document]
    var access: SewnRegistry.Access?
    var totalEarnings: Gita.Credits?    // "total_earnings"
    var metadata: Metadata?
}

struct Metadata: Codable {
    var description: String?
    var tags: [String]
}
```

### Sewn.GroupKind

```swift
enum GroupKind: String, Codable {
    case memory, resonance, document

    var billable: Bool { self != .resonance }
    var label: String  // "Memory" | "Resonance" | "Document" — used in prompts and briefings
}
```

Resolved from **deterministic group id patterns**:

```
"memory-<ownerId>"     → .memory
"resonance-<ownerId>"  → .resonance
anything else          → .document
```

> **Resonance groups are not billable.** They hold passages Sinatra extracted
> from the assistant's own output — paying a user royalties for the assistant's
> words would be circular. Any new group kind must make this decision explicitly.

### Sewn.DocumentStats

```swift
struct DocumentStats: Codable {
    var id: DocumentID
    var totalEarned: Gita.Credits                       // "total_earned"
    var retrievalCount: Int                             // "retrieval_count"
    var sentimentSum: Double                            // "sentiment_sum"
    var lastRetrieved: Date?                            // "last_retrieved"
    var partitionRetrievalCount: [String: Int]          // "partition_retrieval_count"
    var partitionSentiments: [String: PartitionSentiment] // "partition_sentiments"

    var averageSentiment: Double    // sentimentSum / retrievalCount

    struct PartitionSentiment: Codable {
        var retrievalCount: Int  = 0
        var sentimentSum: Double = 0.0
        var lastRetrieved: Date? = nil
        var averageSentiment: Double
    }
}
```

The only thing in `SewnRegistry.documentStats`. Sums and counts are **additive** —
`SewnRegistry.addPerformance` merges by `+=` rather than overwriting, which is
what makes WAL replay idempotent in aggregate. `partitionSentiments` is what
gives Sinatra per-partition engagement rather than a document-level average.

### Sewn.SearchResult

```swift
struct GraphTrace {
    var matchedEntityIds: [String] = []
    var expansionEdgeIds: [String] = []
    var expandedDocuments: Int = 0
}

struct SearchChatResult {
    var context: [String]
    var adjustments: [SinatraAdjustment]
    var references: [Sewn.DocumentReference]
    var contribution: Gita.Contribution?
    var partitions: [Sewn.Partition]
    var trace: Sewn.GraphTrace?
}
```

`GraphTrace` is unioned across Thread nodes — it is how a client can show *why* a
document was retrieved, not just that it was.

### SewnUpdate

```swift
struct SewnUpdate: Codable {
    let documentId: String       // "document_id"
    let operation: Operation
    let targetGroupId: String?   // "target_group_id"

    enum Operation: String, Codable { case remove, access, group }
}
```

### SewnRequest

```swift
struct SewnRequest: Codable {
    let ownerId: String              // "owner_id"
    let group: Sewn.Group?
    let groups: [Sewn.Group]?
    let entities: [String]?
    let tags: [String]?
    let aggregate: Bool?
    let scope: SewnRequestScope?     // .global | .personal
    let threadIds: [String]?         // "thread_ids"
    let personalThreadId: String?    // "personal_thread_id"
    let requestID: String?           // "request_id"

    func from(_ context: SewnRequestContext) throws -> SewnRequest
}

enum SewnRequestScope: String, Codable { case global, personal }
```

`from(_:)` is the security boundary: it requires `context.authUserId` and
**lowercases** the owner id. Never trust `ownerId` off the wire without it.

### Sewn.BatchPutItem

```swift
struct BatchPutItem {
    let id: String
    let texts: [String]
    let tags: [String]
    let tagsEmbedding: [Float]?
    let mediaType: MediaType
    let update: SewnUpdate?
    let name: String?
    let metadata: Data?
}
```

The unit of the write queue. Coalescing merges arrays of these.

### Smaller types

```swift
struct Cost { var tokens: Int; var cost: Int }
struct User: Codable { var groups: [Sewn.Group] }
struct Wearable: Codable {
    var url: URL; var embedding: [Float]; var kind: Kind
    enum Kind: String, Codable { case pin, ring, belt, bracelet, necklace, earring, glasses }
}
```

`Wearable` is forward-looking and unused on any live path.

### Personality

```swift
struct Personality: Codable, Sendable, Equatable, Identifiable {
    var id, name, tagline: String
    var systemFragment: String
    var citationEmphasis: Bool
    var temperature: Float?
    var topP: Float?
    var modelOverride: String?
}

struct ResolvedChatPersona: Equatable, Sendable {
    var name: String
    var voice: String
    var citationEmphasis: Bool
    static let `default`: ResolvedChatPersona
}
```

Persisted at `FilePersistence(key: "personalities")`, cached in a
`LockedValue<[Personality]?>`, falling back to `Personality.defaults`.

---

## Sinatra — `Sources/Sinatra/Models/`

### SinatraRegistry

```swift
struct SinatraRegistry: Codable {
    var parked:            [SewnRegistry.Owner: [SinatraTrainingData.Parked]] = [:]
    var parkedIndices:     [SewnRegistry.Owner: [SinatraTrainingData.ParkedIndex]] = [:]
    var collectors:        [SewnRegistry.Owner: RetrievalDataCollector] = [:]
    var dataSets:          [SewnRegistry.Owner: DataSet] = [:]
    var models:            [SewnRegistry.Owner: GBTModel] = [:]
    var harmonyMemories:   [SewnRegistry.Owner: HarmonyMemory] = [:]
    var lastSentiments:    [SewnRegistry.Owner: Sinatra.Sentiment] = [:]
    var lastSearchEntries: [SewnRegistry.Owner: [SinatraAdjustment.Entry]] = [:]
    var lastTrajectories:  [SewnRegistry.Owner: SinatraTrajectorySnapshot] = [:]
}
```

Nine per-owner maps in one property list. GBT trees serialize into `models`, so
this file grows with model size × owner count.

### Sinatra.Sentiment

```swift
struct Sentiment: Codable {
    enum Kind: Codable, Equatable {
        case positive, negative, neutral, mixed, ambiguous
        case unknown(String)          // ← forward-compatible escape hatch
    }
    enum EmotionalTone: Codable, Equatable {
        case angry, frustrated, satisfied, confused, indifferent,
             excited, sarcastic, curious, awkward, anxious,
             relieved, nostalgic, defensive, playful, disappointed,
             hopeful, overwhelmed, amused, skeptical, embarrassed,
             proud, lonely, grateful, receptive
        case other(String)            // ← same
    }
    // reaction types, key phrases, confidence, notes, attentiveness
}
```

> Both enums have a **catch-all case** with custom `Codable` that round-trips the
> raw string. The LLM can return a value the schema did not anticipate without
> the decode failing. Preserve this pattern in any new enum decoded from model
> output.

### SinatraTone

```swift
struct SinatraTone: Codable {
    var temperature: Float
    var topP: Float                   // "top_p"
    var repetitionPenalty: Float      // "repetition_penalty"
    var repetitionContextSize: Int    // "repetition_context_size"

    static let base = SinatraTone(temperature: 0.4, topP: 0.9,
                                  repetitionPenalty: 1.1, repetitionContextSize: 20)
    static func from(_ adjustments: [SinatraAdjustment]) -> SinatraTone
}
```

### SinatraAdjustment

```swift
struct SinatraAdjustment {
    let partitionCount: Int
    let original: [String]
    let inferred: [String]
    let pqDistanceThreshold: Float
    var entries: [Entry]

    struct Entry: Codable {
        let partitionId: String       // "partition_id"
        let originalDistance: Float   // "original_distance"
        let adjustedDistance: Float   // "adjusted_distance"
        let threshold: Float

        var wasDropped: Bool          // adjustedDistance >= threshold
        var factor: Float             // adjusted / original
        var status: Status            // .boosted <0.98 | .unchanged | .demoted >1.02 | .dropped
    }
}
```

### ML types

```swift
struct GBTHyperparameters {
    var nEstimators = 50, maxDepth = 4
    var learningRate = 0.1, subsample = 0.8, colsampleByTree = 0.8
    var regLambda = 1.0, regAlpha = 0.1, minChildWeight = 3.0, minSplitGain = 0.0
    static func adaptive(datasetSize n: Int) -> GBTHyperparameters
}

struct IndicatorPeriods: Codable, Equatable {   // the 11 IMBHS dimensions
    var emaPeriod, smaPeriod: Int
    var macdFast, macdSlow, macdSignalPeriod: Int
    var stochKPeriod, stochDSignal: Int
    var momentumPeriod, velocityPeriod: Int
    var avgVolPeriod, vwaPeriod: Int
    static var bounds: [(min: Int, max: Int)]
}

struct HarmonyMemory: Codable {
    private(set) var harmonies: [IndicatorPeriods]
    private(set) var fitness: [Double]      // MAE; lower is better; .infinity = unevaluated
    private(set) var generation: Int
    private(set) var activePeriods: IndicatorPeriods
}
```

> `HarmonyMemory.encode(to:)` maps non-finite fitness to
> `Double.greatestFiniteMagnitude`, because `.infinity` cannot go into a property
> list. Any new `Double` that can be infinite needs the same treatment.

### Other Sinatra types

```swift
struct ResonancePartition { let documentId: String; let text: String; let embeddingData: [EmbeddingData] }
struct ResonanceOutput: Decodable { let detected: Bool; let excerpt: String; let confidence: Double }
struct PrepareResult { let ledger: Gita.TokenLedger
                       let documentStatsUpdates: [DocumentID: Sewn.DocumentStats]
                       let resonancePartition: Sinatra.ResonancePartition? }
struct SinatraInference { /* partitionId, distance */ }
struct SinatraTrainingData { struct Parked { … }; struct ParkedIndex { … } }
```

---

## Gita — `Sources/Gita/Models/`

### Credits

```swift
typealias Credits = Double

enum CreditConversion {
    static let creditsPerDollar: Double = 100.0   // 1 credit == $0.01
    static func toDollars(_:) / fromDollars(_:) / formattedCredits(_:) / formattedDollars(_:)
}
```

### Gita.Contribution

```swift
struct TextSpan: Codable, Equatable { let lower: Int; let upper: Int }

struct Contribution: Codable {
    var owners: Set<Owner>
    var totalPayout: Credits
    var serviceCharge: Credits
    var totalCost: Credits
    var ledger: TokenLedger?
    var spenderId: OwnerID?
}

struct Owner: Codable, Hashable {
    var threadId: String
    var ownerId: String?                            // nil ⇒ unauthenticated Thread
    var documentIds: Set<String>
    var influence: [DocumentID: Double]             // sums to 1 WITHIN this owner
    var royalty: Double                             // this owner's share OF THE TURN
    var spans: [Gita.TextSpan]
    var documentSpans: [DocumentID: [Gita.TextSpan]]?
    var earning: Credits
    var identityKey: String { "\(threadId)|\(ownerId ?? "")" }
}
```

Invariant: `owners.map(\.earning).sum + serviceCharge == totalCost`.

`TextSpan` offsets are into the **stripped** (marker-free) visible text.

### TokenLedger & pricing

```swift
struct ModelPricing {
    let promptCreditsPerToken: Credits
    let completionCreditsPerToken: Credits
    func cost(promptTokens: Int, completionTokens: Int) -> Credits
}

// static catalog; unknown models fall back to mistral-medium rates,
// tinker:// checkpoints bill at inkling rates
static let pricing: [String: ModelPricing]
static func pricing(for model: String) -> ModelPricing

struct TokenLedger {
    // one Line per LLM call; totals roll up automatically
    mutating func record(model: String, promptTokens: Int, completionTokens: Int)
}
```

### ServiceChargeStrategy

```swift
struct ServiceChargeStrategy {
    enum Pricing {
        case fixed(Credits)
        case scaled(baseRate: Double, surge: SurgeParameters?)
    }
    struct SurgeParameters {
        let maxConcurrentLoad: Int
        let maxSurgeMultiplier: Double
        func multiplier(currentLoad: Int) -> Double   // linear 1.0 → max
    }
    static let `default` = /* scaled(0.20, surge: 10 concurrent → 2.5×) */
    static func flat(_ credits: Credits) -> ServiceChargeStrategy
}
```

### Spans & payload

```swift
struct CompactCitation { let partitionId: String; let keyWords: [String] }
struct MarkerAnnotation { var visibleText: String
                          var documentSpans: [DocumentID: [Gita.TextSpan]]
                          var markerCount: Int }

struct Payload {
    let partitions: [Sewn.Partition]
    let peerSources: [String: OracleNodeID]   // partitionId → node id
    let coOwners: [DocumentID: Set<OwnerID>]
    // dataSets — reserved for Sinatra trajectory predictions; not wired
}

struct Result { let contribution: Gita.Contribution? }
```

### Wallet

```swift
struct Wallet: Codable, Sendable {
    static let initialBalance: Credits = 1_000_000

    let ownerId: OwnerID              // "owner_id"
    var balance: Credits
    var exchanges: [CreditExchange]
    var transactions: [Transaction]

    var totalSpent: Credits      { exchanges.reduce(0) { $0 + $1.netCost } }      // derived
    var totalCashedOut: Credits  { transactions.reduce(0) { $0 + $1.amount } }    // derived
}

struct WalletRegistry: Codable { /* wallets keyed by owner */ }
struct CreditExchange: Codable { /* one priced inference; netCost */ }
struct Transaction: Codable { let ownerId: OwnerID; let amount: Credits }
```

`totalSpent` and `totalCashedOut` are computed, never stored — they cannot drift
from the records.

---

## API — `Sources/API/Models/`

### Chat

```swift
struct ChatCompletionRequest: Codable    // see Skills/Chat/README.md for the full field list
enum ChatMessageRequestRole: String { case user, assistant, system }
struct ChatMessageRequestData { let role: ChatMessageRequestRole
                                let content: ContentFragmentType
                                let timestamp: Date? }
enum ContentFragmentType { case text(String), fragments([ContentFragment]), none }

struct ChatResult {
    let input: UserInput
    let references: [Sewn.DocumentReference]
    let partitions: [Sewn.Partition]
    let compactCitations: [Gita.CompactCitation]
    let sourceIndex: [Int: DocumentID]
    let personality: Personality?
    let contribution: Gita.Contribution?
    let tone: SinatraTone?
    let autoMemory: Bool
    let sinatraTask: Task<Sinatra.PrepareResult?, any Error>?
}

struct ChatCompletionResponse / ChatCompletionChunkResponse
struct ChatCompletionDelta / ChatMessageResponseData / CompletionUsage
```

`ContentFragmentType` decodes from a single-value container, so `content` accepts
either a string or a multi-modal array.

### Realtime

```swift
struct RealtimeTurnStart: Decodable {
    let type: String
    let request: ChatCompletionRequest    // the SSE route's exact Codable
    let tts: TTSOptions?                  // voice_id, model
}
struct RealtimeInboundProbe: Decodable { let type: String }
enum RealtimePhase: String, Codable, Sendable { case opening, grounded }
enum RealtimeOutbound: Sendable {
    case phase(RealtimePhase), token(RealtimePhase, String)
    case audioBegin(sampleRate: UInt32, channels: UInt16, bits: UInt16)
    case pcm(Data), ttsFailed, metadata(chunkJSON: Data), turnEnd
    case error(stage: String, message: String)
}
```

### Providers

```swift
enum LLMProvider: String, Codable, CaseIterable, Sendable { case mistral, tinker, local }
enum ProviderUnavailable: Error, CustomStringConvertible, Equatable {
    case missingKey(envVar: String), localNotBuilt, localFailed(String), utilityDisabled(LLMProvider)
}
struct ProviderCapabilities: Codable { var chat, skills, code, complete, vision, embeddings, speech: Bool }
struct ProviderInfo: Codable { var id, displayName: String; var available, isDefault: Bool
                               var state: String; var progress: Double?
                               var model: String; var capabilities: ProviderCapabilities
                               var reason: String? }
struct ProvidersResponse: Codable { var providers: [ProviderInfo]; var `default`: String }
struct ProviderWarmResponse: Codable { var accepted: Bool; var state, model: String }
```

> `LLMProvider`'s raw values are the wire, shared with Mary's `LLMEngineChoice`.
> **Never rename a case.**

### Graph & Stats

```swift
struct GraphProxyRequest / GraphProxyResponse
struct GraphProxyEntity / GraphProxyRelationship / GraphProxyDocument / GraphProxyStats
struct StatsResponse { let publicDocumentCount, publicGroupCount: Int }
struct ThreadNodesResponse   // mothership_id, enabled, nodes[]
```

### Generation defaults

```swift
enum GenerationDefaults {
    static let maxTokens = 128
    static let temperature: Float = 0.8
    static let topP: Float = 1.0
    static let stream = false
    static let repetitionPenalty: Float = 1.0
    static let repetitionContextSize = 20
    static let stopSequences: [String] = []
    static let kvGroupSize = 64
    static let quantizedKVStart = 0
}
struct StopCondition { let stopMet: Bool; let trimLength: Int }
```

### Errors

`Sources/API/Errors/` — `MLXServerError`, `ModelProviderError`, `ProcessingError`.

---

## Conduit (external package)

Defined in the sibling Conduit package, not here:

```swift
public struct ThreadNode: Sendable {
    public let threadId: UUID
    public var host: String
    public let grpcPort: Int
    public let httpPort: Int
    public var lastSeen: Date
    public var acceptingStorage: Bool
    public var isActive: Bool { Date().timeIntervalSince(lastSeen) < 60 }
}

public protocol ThreadRegistry: Sendable { /* register / heartbeat / updateAvailability */ }
public protocol ConduitLogger { /* debug / info / warning / error */ }
```

Plus every generated `Thread_V1_*` message. See `Skills/Conduit/README.md`.

---

## Types That No Longer Exist

`PartitionTable`, `PartitionIndex`, `PartitionQuantizer`, `PartitionSlot`,
`GlobalPartitionTable`, `HNSWGraph`, `HNSWVectorStore`, `HNSWTopologyWAL`,
`HNSWNode`, and every Oracle type (`OracleQueryRequest`, `OracleQueryResponse`,
`OraclePartitionResult`, `OracleNode`, trust scores, DAG topology).

The **one** survivor is `typealias OracleNodeID = UUID`, declared in
`Gita.Contribution.swift`. It keys `Gita.Payload.peerSources`
(`partitionId → node id`) and the `peerSources` parameter on
`Gita.royalty(for:)`. Read it as the **Thread-node identity channel** — how an
unauthenticated Thread gets attributed — not as evidence of a peer mesh.

Also note `Sewn.Registry.swift`'s `Access` enum is still used, but only as
`Sewn.Group.access`, populated **from Thread**, not from a local ownership map.
