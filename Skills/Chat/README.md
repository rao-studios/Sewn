# Chat & Completions

The chat completion system is the primary user-facing feature. It wraps local LLM inference (MLX or Mistral API) with RAG retrieval, sentiment-driven tone adjustment, and royalty tracking.

---

## Routes

| Route | Handler | Notes |
|-------|---------|-------|
| `POST /v1/chat/completions` | `ChatCompletions.swift` | Main chat endpoint, stream or non-stream |
| `POST /v1/completions` | `ChatCompletions.swift` | Plain text completion, same LLM path |

---

## Request Flow (Full)

```
POST /v1/chat/completions
    │
    ├─ AuthMiddleware → extract owner_id
    │
    ├─ Parse ChatCompletionRequest
    │   ├─ messages: [{role, content}]
    │   ├─ stream: bool
    │   ├─ temperature / top_p (optional — may be overridden by Sinatra)
    │   └─ max_tokens
    │
    ├─ Extract last user message for embedding
    │
    ├─ EmbeddingModelProvider.embed(last_user_message) → query_vector
    │
    ├─ Sewn.search(query_vector, owner_id, scope: .personal + .global)
    │   ├─ HNSW traversal (local)
    │   ├─ Oracle fan-out (if enabled)
    │   └─ Returns [SearchResult] sorted by score
    │
    ├─ Sinatra.infer(partitions: search_results, owner_id)
    │   ├─ Score partition sentiment
    │   └─ Returns Sinatra.Inference { score, tone, weights }
    │
    ├─ Merge tone: Sinatra.tone overrides request temperature if delta > threshold
    │   └─ "Sinatra wins" when its confidence is high and user didn't explicitly set temp
    │
    ├─ Build system prompt:
    │   ├─ Base: server default system prompt
    │   ├─ Inject retrieved partition texts as context
    │   └─ Prepend: "Use the following context to inform your response:"
    │
    ├─ ModelProvider.generate(messages + system_prompt, tone)
    │   ├─ Stream: return SSE chunks as they arrive
    │   └─ Non-stream: collect full response, return JSON
    │
    ├─ Post-generation (async, non-blocking):
    │   ├─ Sinatra.park(partitions, sentiment_weights)  → queued for GBT training
    │   └─ Gita.track(payload)                         → royalty calculation
    │
    └─ Return ChatCompletionResponse
```

---

## Streaming (SSE)

When `stream: true`, the response is `Content-Type: text/event-stream`.

SSE format:
```
data: {"id":"cmpl-xxx","object":"chat.completion.chunk","choices":[{"delta":{"content":"Hello"}}]}

data: {"id":"cmpl-xxx","object":"chat.completion.chunk","choices":[{"delta":{"content":" world"}}]}

data: [DONE]
```

**Gita billing in streaming**: Token count isn't known until the stream ends. `Gita+StreamBilling.swift` tracks tokens as chunks arrive and finalizes the royalty calculation on `[DONE]`.

**Sinatra parking in streaming**: Parked after stream completes (not during). The `park()` call is made once the full response is assembled.

---

## Non-Streaming

When `stream: false` (or omitted), returns a complete `ChatCompletionResponse`:
```json
{
  "id": "cmpl-xxx",
  "object": "chat.completion",
  "created": 1700000000,
  "model": "sewn-local",
  "choices": [{
    "index": 0,
    "message": { "role": "assistant", "content": "..." },
    "finish_reason": "stop"
  }],
  "usage": {
    "prompt_tokens": 120,
    "completion_tokens": 45,
    "total_tokens": 165
  }
}
```

---

## Model Providers

`ModelProvider` protocol abstracts the LLM backend:

| Provider | CLI Flag | Notes |
|----------|---------|-------|
| MLX (local) | `--model path/to/mlx-model` | On-device inference via MLX-Swift. No network. |
| Mistral API | `--mistral` | Cloud inference via Mistral API. Requires `MISTRAL_API_KEY` env var. |

The server can run one or both. Route handlers use `request.application.modelProvider` to get the active provider.

**Embedding provider** is separate from generation provider. Configured via `--embedding-model`. Falls back to the same model if not specified.

---

## Prompt Cache

When `--enable-prompt-cache` is set:
- The system prompt (with RAG context) is cached in KV cache
- Subsequent messages in the same session reuse the cached prefix
- Cache TTL: `--prompt-cache-ttl-minutes` (default 30)
- Cache size limit: `--prompt-cache-size-mb` (default 1024)

Cache key: `hash(system_prompt + sorted_partition_ids)`. If retrieved partitions change, the cache misses and regenerates.

---

## Sinatra Tone Override Logic

```swift
// In chat completion handler:
let sinatraTone = sinatra.inference.tone
let requestTemp = request.temperature ?? GenerationDefaults.temperature

if sinatra.inference.score > 0.6 || sinatra.inference.score < -0.3 {
    // Sinatra confidence is high — use its tone
    finalTemperature = sinatraTone.temperature
    finalTopP = sinatraTone.top_p
} else {
    // Neutral sentiment — use request defaults
    finalTemperature = requestTemp
    finalTopP = request.top_p ?? GenerationDefaults.top_p
}
```

The threshold (`0.6 / -0.3`) means: only override when Sinatra detects a meaningful emotional signal. Weak neutral sentiment lets the client's requested temperature stand.

---

## RAG Context Injection

Retrieved partitions are injected into the system prompt in score order (highest relevance first):
```
[CONTEXT]
(score: 0.92) From document "article-about-x": "...partition text..."
(score: 0.88) From document "article-about-y": "...partition text..."
[END CONTEXT]

Please use the above context to inform your response.
```

The `(score: ...)` prefix helps the LLM calibrate how much to weight each piece of context.

Partition count in context is capped at `top_k` (default 5). If Oracle is enabled and peer results are included, they're labeled `(peer, score: ...)`.

---

## Text Completions (`POST /v1/completions`)

Simpler path — no message history:
1. Embed prompt
2. Search Sewn for relevant context (same as chat)
3. Build prompt: `[CONTEXT]\n...\n[END CONTEXT]\n\n{prompt}`
4. Generate completion (non-streaming by default)
5. Return `text/plain` or JSON depending on `Accept` header

---

## Summarization Tool (`POST /v1/tools/summarize`)

Single-shot summarization — no RAG, no Sinatra:
1. Build prompt: `"Summarize the following text concisely:\n\n{text}"`
2. Generate with default temperature (no tone adjustment)
3. Return `{ summary: "..." }`

Intentionally simple — it's a utility call, not a conversation.

---

## GenerationDefaults (`Sources/API/GenerationDefaults.swift`)

Default LLM parameters used when neither request nor Sinatra specifies:
```swift
static let temperature: Double = 0.7
static let top_p: Double = 0.9
static let max_tokens: Int = 512
static let repetition_penalty: Double = 1.0
```

These defaults represent a balanced, conversational tone. Adjust them carefully — they affect ALL users on the server.

---

## Prompt Engineering Notes

- System prompt should be short (< 200 tokens) to maximize context window for RAG partitions
- The RAG context block can be up to `top_k × avg_partition_size` tokens — typically 500–1500 tokens
- For 4096-token context models: system (~150) + RAG (~800) + history (~500) + response (~512) ≈ fits
- For 2048-token models: reduce `top_k` to 3 and cap history to last 3 messages

---

## Error Cases

| Scenario | Response |
|----------|---------|
| No auth token | 401 Unauthorized |
| Invalid token | 401 Unauthorized |
| Model not loaded | 503 Service Unavailable |
| Empty message list | 400 Bad Request |
| Search returns 0 results | Chat proceeds without context (base LLM, no RAG) |
| Sinatra inference fails | Chat proceeds with default tone (fallback graceful) |
| Oracle timeout | Chat proceeds with local results only |
| Stream disconnected mid-response | Gita billing finalized with actual tokens sent so far |

---

## Audio-Visual TODO

`ChatCompletions.swift` contains a comment: "When audio-visual aggregation begins (VLM TODO)." When VLM (Visual Language Model) support is added via `--vlm` flag:
- Multimodal messages `{ role, content: [{ type: "image_url", ... }, { type: "text", ... }] }` will need to be parsed
- Image embeddings will need to flow into the RAG search (vision → vector)
- `EmbeddingModelProvider` will need a visual encoding path
