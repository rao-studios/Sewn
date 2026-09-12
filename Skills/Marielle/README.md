# Marielle — Personalization Layer

> **Status: not implemented.** All four routes throw
> `503 Service Unavailable: "Marielle requires Thread-hosted HNSW graph — not yet
> implemented"`. The implementation was written against a local, per-owner HNSW
> graph that no longer exists in this repository.

```swift
let unavailable = HTTPError(.serviceUnavailable,
    message: "Marielle requires Thread-hosted HNSW graph — not yet implemented")
router.post("/v1/marielle/open")      { _, _ in throw unavailable }
router.post("/v1/marielle/proactive") { _, _ in throw unavailable }
router.post("/v1/marielle/interject") { _, _ in throw unavailable }
router.post("/v1/marielle/bridge")    { _, _ in throw unavailable }
```

Source: `Sources/API/Routes/Marielle.swift`, `Sources/Core/Sewn+Marielle.swift`

---

## What Marielle Is

> The point of these routes is personalized experiences that improve or change
> based on the user's profile. Sewn is the A.I. agent user-facing. "Marielle" is
> the internal name for this compartmentalized facet of Sewn.

Four question-generation modes over a user's own corpus:

| Route | Intent |
|-------|--------|
| `POST /v1/marielle/open` | Recency-weighted ice-breaker for a new session |
| `POST /v1/marielle/proactive` | Lightweight check — does Marielle have anything worth saying? |
| `POST /v1/marielle/interject` | Mid-session lateral question scored against live conversation context |
| `POST /v1/marielle/bridge` | A question bridging two users' worlds |

---

## What Still Exists

**The prompts.** `MariellePrompts` (a `fileprivate enum` in `Marielle.swift`) is
written and tuned, with tight word-count constraints to keep questions natural
rather than interrogative. **Do not change them without testing** — they are the
part that was hardest to get right.

**The scoring math.** `Sources/Core/Sewn+Marielle.swift` still carries:

```swift
func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float
func centroid(of embeddings: [[Float]]) -> [Float]
func mariellInterjectScore(…)
```

**The response models.** `MarielleOpenResponse`, `MarielleProactiveResponse`,
`MarielleInterjectResponse`, `MarielleBridgeResponse`, and the matching request
models under `Sources/API/Models/`.

**The bridging opt-in.** This is the one piece of Marielle state still live in
Sewn:

```swift
var bridgingEnabledOwners: Set<OwnerID>   // in SewnRegistry

func bridgingEnabled(for ownerId: OwnerID) -> Bool
mutating func enableBridging(for ownerId: OwnerID)
mutating func disableBridging(for ownerId: OwnerID)
```

It survives in the billing-only registry precisely because it is not Thread's
business: it is consent, not data.

---

## What Is Missing

The graph access layer, and only that. Marielle needs a user's top-k recent
partitions, which used to come from a local per-owner HNSW graph with recency
weighting.

### To implement

1. **Replace local graph access with fan-out.** Either use `fanoutSearch` with a
   `personal` scope, or add a dedicated `fanoutPersonalGraph` / recency-ordered
   library primitive to `Sources/Core/Sewn+ThreadFanout.swift`. Thread would need
   to expose recency-ordered partition retrieval, which means a `thread.proto`
   change in Conduit.

2. **Wire the four handlers.** Replace the `throw unavailable` bodies. The
   prompts, scoring, and response models are all already there — this is
   plumbing, not design.

3. **The bridge route needs two owners' partitions**, so it needs cross-owner
   fan-out with access gating. Two rules to enforce:
   - **Both** owners must have `bridgingEnabled`. One-sided consent is not
     consent.
   - Restricted documents must never surface in bridge output.

4. **`proactive` must stay cheap.** Its whole purpose is to answer "is there
   anything to say" without paying for a full question generation. If the
   implementation ends up costing a fan-out plus an LLM call, it has lost its
   reason to exist — consider answering it from `SewnRegistry.documentStats`
   instead.

---

## Notes for Whoever Picks This Up

- **Recency weighting was the mechanism, not the goal.** The old personal graph
  biased search entry points toward recently inserted nodes. On Thread, the
  equivalent is an explicit recency ordering — don't try to recreate entry-point
  bias.
- **Sinatra's resonance group is a better source than raw recency.** Documents in
  the `"Resonance"` group are passages the user demonstrably engaged with, which
  is closer to what Marielle wants than "most recently uploaded". That group did
  not exist when Marielle was first written.
- **Session boundaries are already detected.** Sinatra's
  `sessionBoundaryDetected` (pace collapse + attentiveness reset) is exactly the
  "user is returning" signal `open` wants, and it is computed for free on every
  turn.
- Marielle has no tests. `Flow13` was reserved for them and never written.
