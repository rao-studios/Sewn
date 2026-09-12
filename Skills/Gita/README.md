# Gita — Attribution, Royalty & Wallet

Gita decides **who gets paid**. It runs in three stages, and the separation is
the whole design:

| Stage | When | From what |
|-------|------|-----------|
| **1. Shares** | At search time | Word counts across the retrieved text |
| **2. Spans** | After generation | The `[[n]]` markers the model emitted |
| **3. Pricing** | Last | The turn's real token ledger |

Retrieval knows *which documents* were consulted and in what proportion. Only
the generated text reveals *which sentences actually used them*. And only after
every LLM call in the turn has completed is the real cost known. Hence three
stages, in that order.

Source: `Sources/Gita/`

---

## Components

```
Gita (class — NOT an actor; held by the Sewn actor)
  ├── walletRegistry: WalletRegistry     — all owner wallets + exchanges
  ├── walletPersistence: FilePersistence — key "wallet_registry"
  ├── Gita+Royalty.swift                 — word-count shares, pricing, documentEarnings
  ├── Gita+MarkerSpans.swift             — [[n]] → exact character spans
  ├── Gita+Spans.swift                   — n-gram heuristic spans, compact citations
  ├── Gita+StreamBilling.swift           — SSE billing
  └── Wallet/
      ├── Gita+Wallet.swift              — wallet ops
      ├── Gita.CreditExchange.swift      — one priced inference
      └── Gita.WalletRegistry.swift      — registry state
```

Entry point:

```swift
enum Command { case put, delete, inference }

@discardableResult
func track(_ payload: Gita.Payload, command: Command, request: SewnRequest? = nil) -> Gita.Result
```

Only `.inference` does work today. `.put` and `.delete` return an empty result —
they are placeholders for on-chain document registration.

---

## Credits

```swift
/// Conversion: $0.10 USD == 10 credits  →  1 credit == $0.01 USD
static let creditsPerDollar: Double = 100.0
```

`Gita.CreditConversion` converts both ways and formats for display. Every
monetary value in Gita is `Credits`, never dollars.

---

## Stage 1 — Royalty Shares (`Gita+Royalty.swift`)

```swift
func royalty(
    for partitions: [Sewn.Partition],
    peerSources: [String: OracleNodeID] = [:],
    coOwners: [DocumentID: Set<OwnerID>] = [:],
    request: SewnRequest? = nil
) -> Gita.Contribution
```

### Word counts in a single pass

```swift
var documentCounts = [DocumentID: Int]()
for partition in partitions {
    documentCounts[partition.documentId, default: 0] += partition.text
        .components(separatedBy: .whitespacesAndNewlines).count
}
let totalTextCount = documentCounts.values.reduce(0, +)
```

The single pass happens **before** the per-owner loop deliberately: counts are
then stable regardless of iteration order and cannot be inflated across owner
boundaries. Empty partitions return an empty contribution rather than dividing by
zero.

### Attribution and co-ownership

For each document, determine its `(threadId, ownerId)` candidates:

| Case | Candidates |
|------|-----------|
| `coOwners[documentId]` non-empty | Every co-owner, each with the `threadId` from the first matching partition |
| Otherwise | The first partition's `(threadId, ownerId)` |
| `ownerId` is an empty string | Treated as `nil` — an **unauthenticated Thread**, grouped by `threadId` instead |

```swift
let share = Double(wordCount) / Double(candidates.count)   // equal split
```

The grouping key is `ownerId ?? threadId`. That fallback is what lets an
unauthenticated Thread node still earn: the node itself becomes the payee.

### Per-owner output

```swift
let royalty   = ownerTotal / Double(totalTextCount)   // 0.0–1.0, sums to 1 across owners
let influence = group.docs.mapValues { $0 / ownerTotal }  // per-document, sums to 1 within owner
```

Two normalizations at different levels, which is worth keeping straight:
`royalty` is the owner's share **of the turn**; `influence` is each document's
share **of that owner's contribution**.

> **Equal split among co-owners is the deliberate baseline.** `Gita+Royalty.swift`
> carries a long TODO for weighting by document kind (research paper > article >
> social post), retrieval count, and recency decay. Doing that requires passing
> `documents: [DocumentID: Sewn.Document]` into `royalty(for:)` and re-normalizing
> after multipliers so shares still sum to 1.0.

---

## Stage 2 — Spans

Attribution runs in three tiers of decreasing confidence. Higher tiers win.

### Tier 1 — compact citations (`Gita+Spans.swift`)

```swift
struct CompactCitation {
    let partitionId: String
    let keyWords: [String]   // ordered content words from compact-summary sentences citing this partition
}

static func extractCitations(from compactText:partitions:requestOwnerId:) -> [CompactCitation]
```

The compact prompt instructs the LLM to reference sources by quoted title (e.g.
`"startup-notes"`). This scans the compact output for sentences containing a known
source name and attaches their content words to the matching partition. **No extra
LLM call** — it is deterministic post-processing.

These key words are the most reliable seed because they are closer to the phrasing
the response model actually saw than the raw partition text is.

Note that the verbatim-context path in `Sewn+Compact.swift` produces **no**
compact text, so this tier is empty for small retrievals.

### Tier 2 — exact markers (`Gita+MarkerSpans.swift`)

The chat model appends invisible `[[n]]` markers to sentences drawing on
bracketed source `[n]`.

```swift
private static let markerPattern = #/\[\[(\d{1,3})\]\]/#

struct MarkerAnnotation {
    var visibleText: String
    var documentSpans: [DocumentID: [Gita.TextSpan]]
    var markerCount: Int
}

static func parseMarkers(_ text: String, sourceIndex: [Int: DocumentID]) -> MarkerAnnotation
```

Rules that matter:

- **Markers are always stripped**, whether or not a contribution exists. They can
  never reach the client.
- Each marker attributes **the sentence it terminates**, with offsets in the
  *stripped* text — not the raw text. Getting this wrong shifts every span.
- Runs like `[[1]][[3]]` match repeatedly and attribute the same sentence to both
  sources.
- An **unknown index strips silently** without attribution. A model citing `[[9]]`
  when only three sources exist produces clean text and no bogus span.
- Extended regex delimiters (`#/…/#`) are used because bare-slash regex literals
  are not enabled in this target.

### Tier 3 — n-gram heuristic (`Gita+Spans.swift`)

For sentences with no marker, mirroring `ContributionSpanGenerator` on the client:

1. Split the response into sentences; group into `ContentChunk`s of at least
   `minContentWords`.
2. Rank owners by peak influence. For each owner's partitions (ranked by
   influence), find the best **unclaimed** chunk by overlap coefficient on
   content-word sets.
3. Merge adjacent claimed chunks per owner into contiguous `TextSpan`s.

Heuristic spans overlapping an exact span are dropped — the exact tier wins
wherever the two disagree.

### TextSpan

```swift
struct TextSpan: Codable, Equatable {
    let lower: Int
    let upper: Int
}
```

Character offsets into the visible text, so the client can reconstruct a
`Range<String.Index>` and highlight without another round trip.

---

## Stage 3 — Pricing

### The token ledger

```swift
var ledger = Gita.TokenLedger()
ledger.record(model: "mistral-medium", promptTokens: …, completionTokens: …)
```

One `Line` per LLM call, totals rolling up automatically. A single chat request
may invoke a model **four or five times** — resonance extraction, sentiment
scoring, compaction, auto-memory, and the generation itself. All of it is billed
to the turn that caused it, including the calls the user never sees.

```swift
struct ModelPricing {
    let promptCreditsPerToken: Credits
    let completionCreditsPerToken: Credits
}

static func pricing(for model: String) -> ModelPricing
```

A static catalog in `Gita.TokenLedger`, sourced from provider list pricing and
converted to credits. Unknown models fall back to **`mistral-medium` rates**;
`tinker://…` fine-tuned checkpoints bill at inkling rates. **Adding a model to
`ModelConfig` without adding it to this catalog silently mis-prices every turn
that uses it.**

### Service charge

```swift
/// Invariant:  ownerPayouts.sum + serviceCharge == totalCost
struct ServiceChargeStrategy {
    enum Pricing {
        case fixed(Credits)
        case scaled(baseRate: Double, surge: SurgeParameters?)
    }
}

static let `default` = ServiceChargeStrategy(
    pricing: .scaled(baseRate: 0.20,
                     surge: SurgeParameters(maxConcurrentLoad: 10, maxSurgeMultiplier: 2.5))
)
```

Surge is linear in concurrent load:

```swift
func multiplier(currentLoad: Int) -> Double {
    let clamped = min(Double(currentLoad), Double(maxConcurrentLoad))
    let ratio   = clamped / Double(maxConcurrentLoad)
    return 1.0 + ratio * (maxSurgeMultiplier - 1.0)
}
```

At load 1 of a 10-request ceiling this is already **1.15×** — a deliberate 15% on
top of the base rate to smooth the ramp-up rather than starting flat.

### priceContribution

```swift
func priceContribution(
    _ contribution: Gita.Contribution,
    ledger: TokenLedger,
    strategy: ServiceChargeStrategy = .default,
    currentLoad: Int = …,
    request: SewnRequest? = nil
) -> Gita.Contribution
```

Takes an attribution-only contribution and returns a priced copy satisfying
`owners.map(\.earning).sum + serviceCharge == totalCost`.

It emits three structured log lines tagged `service: .gita, flow: .chat` — 
**Token Ledger**, **Cost Breakdown** (with surge info), and **Owner Payouts**.
Those three lines are the fastest way to debug a pricing question.

### Per-document earnings

```swift
func documentEarnings(from contribution: Gita.Contribution) -> [DocumentID: Credits] {
    // documentEarning[docId] = owner.earning × owner.influence[docId]
}
```

Note the filter: `owner.earning > 0 && owner.ownerId != contribution.spenderId`.
**An owner does not earn royalties from querying their own documents.** The
result feeds `RegistryMutator.accumulateEarnings`.

---

## Gita.Contribution

```swift
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
    var ownerId: String?                                  // nil ⇒ unauthenticated Thread
    var documentIds: Set<String>
    var influence: [DocumentID: Double]                   // sums to 1 within this owner
    var royalty: Double                                   // this owner's share of the turn
    var spans: [Gita.TextSpan]
    var documentSpans: [DocumentID: [Gita.TextSpan]]?
    var earning: Credits
    var identityKey: String { "\(threadId)|\(ownerId ?? "")" }
}
```

`identityKey` is the composite identity: the same owner id reached through two
different Thread nodes is two entries. `debugDescription` and
`ownersDebugDescription` render the distribution for logs.

---

## Wallet

```swift
struct Wallet: Codable, Sendable {
    static let initialBalance: Credits = 1_000_000     // every new wallet starts funded

    let ownerId: OwnerID
    var balance: Credits
    var exchanges: [CreditExchange]
    var transactions: [Transaction]

    var totalSpent: Credits      { exchanges.reduce(0)    { $0 + $1.netCost } }
    var totalCashedOut: Credits  { transactions.reduce(0) { $0 + $1.amount } }
}
```

| Operation | Effect |
|-----------|--------|
| `initializeWallet(for:)` | Creates the wallet at `initialBalance` if absent — idempotent |
| `recordExchange(_:spenderId:)` | One priced inference: `CreditExchange` appended, balance debited |
| `recordCashout(ownerId:amount:)` | Appends a `Transaction` |
| `addBalance(_:)` | Credits in |

`totalSpent` and `totalCashedOut` are **derived**, not stored — they cannot drift
from the underlying records.

Persistence is `FilePersistence(key: "wallet_registry")`, restored in `Gita.init`
with `?? .init()`.

### `GET /v1/wallet`

```swift
struct WalletResponse: Codable {
    let totalEarnings: Gita.Credits    // cumulative across all the owner's groups
    let balance: Gita.Credits
    let totalSpent: Gita.Credits
    let totalCashedOut: Gita.Credits
    // + per-group earnings breakdown
}
```

---

## Stream Billing (`Gita+StreamBilling.swift`)

For SSE responses the completion token count is unknown until the stream ends:

1. Shares are computed at search time as usual — they do not depend on the
   response.
2. Tokens accumulate as chunks arrive.
3. On stream end, the ledger is finalized and `priceContribution` runs.
4. The contribution is sent as a trailing chunk.

If the client disconnects mid-stream, billing finalizes on the tokens actually
generated. Markers are stripped from every delta, so a disconnect cannot leak
one.

---

## GitaContract

`Sources/Gita/Models/GitaContract.swift` — the Web3 interface stub. Not active.
`Web3.swift` is already a `Package.swift` dependency, so the scaffolding exists
for on-chain settlement and ERC-20 cashout, but nothing calls it.

---

## Vestigial Oracle Types

```swift
typealias OracleNodeID = UUID
```

The P2P Oracle mesh is gone. What survives is this typealias and
`Gita.Payload.peerSources` / the `peerSources` parameter on `royalty(for:)`,
mapping `partitionId → OracleNodeID`. `Sewn+Search.swift` still declares
`var peerSources: [String: OracleNodeID] = [:]`. Treat these as the
**Thread-node identity channel**, not as evidence of a peer mesh — they are how
an unauthenticated Thread gets attributed.

---

## Building a New Feature That Touches Gita

1. **New royalty weight factor** → `royalty(for:)`. You will need document
   metadata passed in; re-normalize after applying multipliers so shares still
   sum to 1.0.
2. **New model** → add it to the `Gita.TokenLedger` pricing catalog at the same
   time you add it to `ModelConfig`. The fallback silently prices at
   `mistral-medium`.
3. **New span tier** → keep the precedence rule: higher-confidence tiers win and
   overlapping lower-tier spans are dropped.
4. **New charge strategy** → add a `Pricing` case and preserve the invariant
   `ownerPayouts.sum + serviceCharge == totalCost`.
5. **New wallet field** → prefer a derived property over a stored one.
6. **Tests** → `Flow2_GitaCreditTests`, `Flow2_GitaRoyaltyTests`,
   `Flow2_GitaSpanTests`, `Flow2_GitaWalletTests`, `MarkerSpanTests`.

---

## Known Gaps

- **Weighted influence** — shares are pure word count; the kind / retrieval-count
  / recency weighting is specified in comments but not implemented.
- **Cashout** — `recordCashout` appends a transaction; no on-chain withdrawal
  exists.
- **Wallet encryption** — the wallet registry is an unencrypted property list.
- **`Gita.Payload.dataSets`** — reserved for Sinatra trajectory predictions
  feeding royalty weights; not wired.
- **Cross-node settlement** — `peerSources` attributes an unauthenticated Thread,
  but there is no protocol for paying a remote wallet.
