# Realtime — The Two-Pass Voice Turn

`GET /v1/realtime/chat` is a WebSocket upgrade that trades a little quality on
the first sentence for a large drop in time-to-first-audio. An **opening pass**
speaks from conversation history while retrieval is still in flight; a
**grounded pass** then carries the rest of the turn over the retrieved context.

```
Sources/API/Routes/Realtime/
  ├── Realtime.swift          — the route, upgrade, socket loop
  ├── RealtimeTurnEngine.swift — orchestration (provider-agnostic, scriptable)
  └── RealtimeWire.swift       — the frame protocol
```

---

## One Turn Per Connection

> The client sends a single `turn.start` frame (embedding the exact
> `ChatCompletionRequest` JSON the SSE route accepts), the server streams
> interleaved text tokens and TTS PCM, then a metadata chunk (contribution,
> auto_memory) and `turn.end`. Client close (or a `cancel` frame) at any point
> cancels all in-flight work — **that IS the barge-in path.**

```
Client                               Sewn
  │── WebSocket upgrade ─────────────►│  bearer validated in shouldUpgrade
  │── {"type":"turn.start", …} ──────►│
  │◄── phase: opening ────────────────│
  │◄── token(opening, …) ─────────────│  fast model, history only
  │◄── audio.begin + PCM frames ──────│
  │◄── phase: grounded ───────────────│
  │◄── token(grounded, …) ────────────│  primary model over retrieved context
  │◄── PCM frames ────────────────────│
  │◄── metadata(chunkJSON) ───────────│  contribution + auto_memory
  │◄── turn.end ──────────────────────│
```

---

## The Wire (`RealtimeWire.swift`)

### Inbound

```swift
struct RealtimeTurnStart: Decodable {
    let type: String
    let request: ChatCompletionRequest      // ← the SSE route's exact Codable
    let tts: TTSOptions?                    // voice_id, model
}

struct RealtimeInboundProbe: Decodable { let type: String }
```

> `request` is the exact `ChatCompletionRequest` JSON the SSE route accepts —
> **one Codable, one wire shape, two transports.** Adding a chat feature to the
> SSE route gives it to realtime for free.

After `turn.start`, only `{"type":"cancel"}` is meaningful, and a socket close is
equivalent.

### Outbound

```swift
enum RealtimePhase: String, Codable, Sendable { case opening, grounded }

enum RealtimeOutbound: Sendable {
    case phase(RealtimePhase)
    case token(RealtimePhase, String)
    case audioBegin(sampleRate: UInt32, channels: UInt16, bits: UInt16)
    case pcm(Data)
    case ttsFailed
    case metadata(chunkJSON: Data)
    case turnEnd
    case error(stage: String, message: String)
}
```

Design rules baked into this enum:

- **JSON text frames throughout, except PCM, which rides raw binary frames.**
  Ordering on the socket implies audio sequence; `audio.begin` announces the
  format **once** (f32 LE mono, 24 kHz from `MistralTTS.sampleRate`).
- `metadata` carries a **pre-encoded `ChatCompletionChunkResponse`** — the SSE
  trailing chunk with empty `choices` plus contribution and `auto_memory` —
  reused verbatim so clients decode it with their existing chunk Codable.
- Every token frame is tagged with its phase, so a client can style or discard
  the opening.
- JSON is serialized with `.sortedKeys` for stable frames.

---

## Authentication

```swift
router.ws("/v1/realtime/chat",
          shouldUpgrade: { request, _ in
              guard let token = bearerToken(from: request) else {
                  throw HTTPError(.unauthorized, message: "Missing bearer token")
              }
              _ = try await TokenValidator.validate(token)
              return .upgrade([:])
          },
          onUpgrade: { inbound, outbound, context in … })
```

Same bearer scheme as `AuthMiddleware`, validated **before the upgrade
completes** — an unauthorized client never gets a socket. `TokenValidator`
caches by token, so the handler's second `validate()` is a dictionary hit.

The WS routes live on a **separate router** with `BasicWebSocketRequestContext`
(`configureWebSocketRoutes`), so upgrade matching never scans HTTP-only routes.

---

## The Turn Engine

```swift
struct RealtimeTurnEngine {
    struct Deps {
        var opening:   @Sendable ([[String: String]]) async throws -> AsyncThrowingStream<StreamDelta, Error>
        var retrieval: @Sendable () async throws -> ChatResult
        var grounded:  @Sendable (UserInput.Prompt) async throws -> AsyncThrowingStream<StreamDelta, Error>
        var tts:       @Sendable (String) async throws -> AsyncThrowingStream<Data, Error>
    }
}
```

> All provider work arrives as **injected closures**, so the engine is fully
> scriptable offline; all outbound frames flow through a **single writer loop**
> so frame order on the socket is deterministic per producer.

That is the testability seam — `RealtimeTests.swift` drives the whole engine with
no network.

### Structure of `run(send:)`

```swift
let (frames, frameCont) = AsyncStream<RealtimeOutbound>.makeStream()

withThrowingTaskGroup {
    group.addTask { for await frame in frames { try await send(frame) } }   // THE writer
    group.addTask { defer { frameCont.finish() }
                    summaryBox.withLock { $0 = try await orchestrate { frameCont.yield($0) } } }
    do { try await group.waitForAll() }
    catch { group.cancelAll(); throw error }
}
```

One writer task drains the frame stream; the orchestrator only ever *yields*.
A `send` failure — the client closed the socket — cancels every in-flight task
and rethrows. That is barge-in, implemented as cancellation rather than as a
protocol.

### Orchestration

```
startNs
  │
  ├─ retrievalTask = Task { deps.retrieval() }        ← starts IMMEDIATELY
  │     (defer: cancel)
  │
  ├─ TTS lane: ONE sequential worker consuming an AsyncStream<String>
  │     ├─ first PCM chunk → emit(.audioBegin(24 kHz, 1ch, 32-bit))
  │     ├─ emit(.pcm) per chunk
  │     ├─ CancellationError → treated as success
  │     └─ any other error  → emit(.ttsFailed), log, TEXT CONTINUES WITHOUT AUDIO
  │
  ├─ Opening pass: deps.opening(history) — no retrieval, fast model
  │     └─ sentences pushed into the TTS lane as they complete
  │
  ├─ await retrievalTask
  │     ├─ success → grounded prompt over the retrieved context
  │     └─ failure → degradedInstruction (answer from conversation alone)
  │
  ├─ Grounded pass: deps.grounded(prompt) — [[n]] markers included
  │
  └─ Summary { openingText, groundedRaw, accumulatedText, chatResult,
               ttsFailed, firstTokenMs, firstAudioMs, retrievalWaitMs }
```

**The TTS lane is one sequential worker on purpose.** Audio frames must stay
ordered, and parallel synthesis would interleave them.

**TTS failure is not turn failure.** The lane emits `.ttsFailed` and the text
stream continues — a voice client degrades to a text client rather than dying.

### The seam between passes

```swift
/// Continue the opening mid-message via assistant prefill. Constant switch:
/// if Inkling's thinking phase misbehaves under prefill, flip to `false`
/// and a "Continue your reply." user nudge is appended instead.
static let useAssistantPrefill = true

static let seamInstruction = """
The assistant text already streamed to the user is the opening of your reply — continue it seamlessly. \
Never restate it, never contradict it, never greet again; pick up exactly where it left off.
"""
```

This is the hardest part of the design: the user has already *heard* the opening,
so the grounded pass must continue mid-thought rather than start over. Prefill is
the mechanism; `seamInstruction` is the fallback instruction that makes it hold.
`useAssistantPrefill` is a deliberate constant switch, not a config value.

### Degraded retrieval

```swift
static let degradedInstruction = """
Retrieval is unavailable for this turn. Answer fully from the conversation alone — do not reference, \
invent, or imply retrieved memories or documents.
"""
```

A retrieval failure produces a complete answer with an explicit instruction not
to imply memories it does not have. `sewn.realtime.retrieval_failures_total`
counts these.

---

## The `local` Provider Skips the Opening

On `local` the opening pass is **skipped entirely** and the grounded stream
carries the whole turn. Two reasons: a single GPU cannot run the opening and the
grounded pass concurrently, and the opening's only purpose is to cover network
latency that does not exist on-device. The consequence is that a `local` realtime
turn makes **no outbound request at all**.

---

## Attribution in Realtime

`Summary` keeps `groundedRaw` (with `[[n]]` markers) separate from
`accumulatedText` (markers stripped, both phases). Markers are stripped from
every emitted token, so they can never reach the client even mid-stream. The
final `metadata` frame carries the contribution and spans built from
`groundedRaw`.

Opening-pass text is **not** attributed — it was generated without retrieval, so
there is nothing to attribute it to.

---

## Metrics

| Metric | Meaning |
|--------|---------|
| `sewn.realtime.turns_total` | Turns started |
| `sewn.realtime.first_token` | Time to first text token |
| `sewn.realtime.first_audio` | Time to first PCM frame — **the number this design exists to lower** |
| `sewn.realtime.retrieval_wait` | How long the grounded pass waited on retrieval |
| `sewn.realtime.tts_failures_total` | Turns that lost audio |
| `sewn.realtime.retrieval_failures_total` | Turns answered degraded |

If `first_audio` is not well below `retrieval_wait`, the two-pass design is
buying nothing and the opening pass should be examined.

---

## Working on Realtime

1. **New frame type** → add a `RealtimeOutbound` case and its `Payload`
   encoding. Text frames are JSON with sorted keys; binary is PCM only.
2. **New request field** → it belongs on `ChatCompletionRequest`, so SSE and
   realtime stay one shape.
3. **New provider work** → add a closure to `Deps`, never a direct provider call
   inside the engine. That is what keeps `RealtimeTests` offline.
4. **Emitting frames** → always `yield` into the frame stream. A direct `send`
   from the orchestrator breaks ordering.
5. **Cancellation** → treat `CancellationError` as success in any lane. It means
   barge-in, not failure.
6. **Tests** → `RealtimeTests.swift`, plus `HummingbirdWSTesting` for the
   upgrade path.
