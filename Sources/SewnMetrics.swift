//
//  SewnMetrics.swift
//  sewn-server
//

import Metrics

/// Central registry of Prometheus-backed metrics for the Sewn server.
///
/// Metrics are backed by `PrometheusMetricsFactory` (bootstrapped in `SewnServer.setupApplication`).
/// Alloy scrapes `/metrics` every 30 s and remote-writes to Scaleway Cockpit Mimir.
///
/// Naming convention: `<service>.<component>.<noun>` using underscores in Prometheus output.
enum SewnMetrics {
    // MARK: - HTTP traffic
    /// Total HTTP requests received, labelled by route, ip, region, and country_code.
    /// Incremented via inline Counter with dimensions in IPMetricsMiddleware.

    // MARK: - Search
    /// Total search requests handled (embed + HNSW/PQ lookup combined).
    static let searchTotal = Counter(label: "sewn.search.total")
    /// End-to-end table search duration (HNSW/PQ scan only, excludes embedding time).
    static let searchDuration = Timer(label: "sewn.search.duration")

    // MARK: - Chat pipeline (pre-stream legs + stream health)
    /// Retrieval leg of a chat turn (Thread fan-out or local search, end to end).
    static let threadSearchDuration = Timer(label: "sewn.chat.search_duration")
    /// Context-compaction leg (verbatim injection or LLM briefing).
    static let compactDuration = Timer(label: "sewn.chat.compact_duration")
    /// Request receipt → first visible streamed token.
    static let chatTTFT = Timer(label: "sewn.chat.ttft")
    /// First visible token → stream completion.
    static let chatStreamDuration = Timer(label: "sewn.chat.stream_duration")

    // MARK: - Realtime route (WebSocket chat + interleaved TTS)
    /// Total realtime turns started.
    static let realtimeTurns = Counter(label: "sewn.realtime.turns_total")
    /// turn.start → first visible token (either phase).
    static let realtimeFirstToken = Timer(label: "sewn.realtime.first_token")
    /// turn.start → first PCM frame on the socket.
    static let realtimeFirstAudio = Timer(label: "sewn.realtime.first_audio")
    /// Gap between the opening finishing and retrieval becoming available —
    /// the audible seam the opening pass exists to cover.
    static let realtimeRetrievalWait = Timer(label: "sewn.realtime.retrieval_wait")
    /// Turns whose TTS lane failed (text continued, audio stopped).
    static let realtimeTTSFailures = Counter(label: "sewn.realtime.tts_failures_total")
    /// Turns whose retrieval pipeline failed (degraded grounded pass).
    static let realtimeRetrievalFailures = Counter(label: "sewn.realtime.retrieval_failures_total")

    // MARK: - HNSW graph traversal (approximate last-seen values per query)
    /// Upper-layer hops taken during the greedy graph walk.
    static let hnswUpperHops = Gauge(label: "sewn.hnsw.upper_layer_hops")
    /// Candidates examined at layer 0 (ef_search budget consumed).
    static let hnswLayer0Explored = Gauge(label: "sewn.hnsw.layer0_explored")
    /// Effective ef ceiling used for the last base-layer beam search: max(k, efSearch).
    static let hnswEfUsed = Gauge(label: "sewn.hnsw.ef_used")
    /// Candidate set size before owner/access filtering.
    static let hnswCandidates = Gauge(label: "sewn.hnsw.candidates_before_filter")
    /// Live node count in the global HNSW graph after each search.
    static let hnswNodes = Gauge(label: "sewn.hnsw.nodes_total")

    // MARK: - HNSW adaptive efSearch
    /// Current stored efSearch value after adaptive calibration (the floor, not max(k, efSearch)).
    static let hnswEfSearch = Gauge(label: "sewn.hnsw.ef_search")
    /// EMA of layer-0 exploration depth driving the efSearch adaptation target.
    static let hnswEmaExplored = Gauge(label: "sewn.hnsw.ema_explored")
    /// Total times efSearch changed value due to adaptation (not just every call to adaptEf).
    static let hnswEfAdaptations = Counter(label: "sewn.hnsw.ef_adaptations_total")

    // MARK: - HNSW graph health (periodic snapshots)
    /// Maximum layer reached in the global HNSW hierarchy.
    static let hnswMaxLevel = Gauge(label: "sewn.hnsw.max_level")
    /// Live (non-deleted) node count in the global HNSW graph.
    static let hnswLiveNodes = Gauge(label: "sewn.hnsw.live_nodes")
    /// Soft-deleted node count pending the next compaction.
    static let hnswDeletedNodes = Gauge(label: "sewn.hnsw.deleted_nodes")
    /// Average number of layer-0 neighbours per live node.
    static let hnswAvgLayer0Degree = Gauge(label: "sewn.hnsw.avg_layer0_degree")
    /// Total compaction runs that removed at least one deleted node.
    static let hnswCompactions = Counter(label: "sewn.hnsw.compactions_total")

    // MARK: - Product Quantization training
    /// Wall-clock time to train a PQ codebook for one document (milliseconds).
    static let pqTrainDuration = Timer(label: "sewn.pq.train_duration")

    // MARK: - Index lifecycle
    /// Total number of indexed documents (keys in PartitionTable).
    static let indexDocuments = Gauge(label: "sewn.index.documents_total")

    // MARK: - Batch embedding pipeline
    //
    // These four metrics together produce a stage-by-stage trace of every batch
    // embedding request so memory and CPU spikes can be correlated to the exact
    // phase that caused them:
    //
    //   phase1_preprocess  — sanitize + dedup (concurrent, capped at maxPreprocessConcurrent)
    //   phase2_embed       — single Mistral embedding API call
    //   phase3_index       — HNSW insertions inside tableMutator.putBatch
    //
    // Dashboard recipe: overlay `sewn_batch_phase_duration_ms{phase="phase3_index"}`
    // against `process_resident_memory_bytes` on the same time axis. The memory
    // growth should track with phase3 duration, confirming HNSW node allocation
    // as the primary driver.

    /// Wall-clock duration of each batch pipeline phase (milliseconds).
    /// Labelled by `phase`: phase1_preprocess | phase2_embed | phase3_index.
    static let batchPhaseDuration = Timer(label: "sewn.batch.phase_duration")

    /// Total documents counted at each pipeline stage.
    /// Labelled by `state`: received | prepared | skipped | failed.
    /// `received` = raw inputs; `prepared` = texts survived dedup; `skipped` = already indexed;
    /// `failed` = empty after sanitize. Use `prepared / received` to track dedup hit rate.
    static let batchDocuments = Counter(label: "sewn.batch.documents_total")

    /// Number of write jobs currently waiting in the IndexQueue.
    /// Spikes here mean put/remove jobs are arriving faster than HNSW can consume them.
    /// Each queued put job holds its `[BatchPutItem]` (embeddings + texts) in memory
    /// until the drain task reaches it — this is the primary cause of memory pressure
    /// between phase 2 completing and phase 3 starting.
    static let indexQueueDepth = Gauge(label: "sewn.index.queue_depth")

    /// Total documents held in memory across all pending IndexQueue put jobs.
    /// A more precise memory proxy than queue_depth when batch sizes vary between requests.
    static let indexQueueItems = Gauge(label: "sewn.index.queue_items")

    // MARK: - Sinatra pipeline
    /// Parked partition records currently awaiting a follow-up user message.
    static let sinatraParked = Gauge(label: "sinatra.parked_records")
    /// Most recent sentiment weight produced by the LLM analyser (0 = negative, 1 = positive).
    static let sinatraSentimentWeight = Gauge(label: "sinatra.sentiment_weight")
    /// LLM confidence in the most recent sentiment assessment (0–1).
    static let sinatraSentimentConfidence = Gauge(label: "sinatra.sentiment_confidence")
    /// Feature vectors successfully generated from parked items and added to the dataset.
    static let sinatraFeatureVectorsGenerated = Counter(label: "sinatra.feature_vectors_generated_total")
    /// Parked items skipped during feature generation (insufficient interaction history).
    static let sinatraFeatureVectorsSkipped = Counter(label: "sinatra.feature_vectors_skipped_total")
    /// Current training-sample count for the most recently trained user's dataset.
    static let sinatraDatasetSize = Gauge(label: "sinatra.dataset_size")
    /// GBT training runs completed (labelled by tier: small / medium / full). Incremented via inline Counter with dimensions.
    /// Wall-clock time for one full GBT training run (nanoseconds → histogram).
    static let sinatraTrainingDuration = Timer(label: "sinatra.training_duration")
    /// Tree count in the most recently trained GBT model.
    static let sinatraModelTrees = Gauge(label: "sinatra.model_trees_total")
    /// F₀ initial prediction of the most recently trained GBT model (mean of training targets).
    static let sinatraModelInitialPrediction = Gauge(label: "sinatra.model_initial_prediction")
    /// Current IMBHS generation for the most recently optimised user.
    static let sinatraImbhsGeneration = Gauge(label: "sinatra.imbhs_generation")
    /// Best (lowest) MAE fitness score in the harmony memory after the last IMBHS step.
    static let sinatraImbhsFitness = Gauge(label: "sinatra.imbhs_fitness")
    /// IMBHS improvisation steps where activePeriods changed and GBT was retrained.
    static let sinatraImbhsTunings = Counter(label: "sinatra.imbhs_period_tunings_total")

    // MARK: - Sinatra inference
    /// Total inference calls (every partition scored, regardless of outcome).
    static let sinatraInferences = Counter(label: "sinatra.inferences_total")
    /// Inferences where the GBT model was ready and an adjustment was applied.
    static let sinatraAdjustments = Counter(label: "sinatra.adjustments_total")
    /// Inferences that returned unadjusted (labelled by reason: no_registry / no_collector / no_model / empty_model / no_features). Incremented via inline Counter with dimensions.
    /// Most recently applied distance adjustment factor (0.5 = max boost, 1.0 = neutral, 1.5 = max demote).
    static let sinatraAdjustmentFactor = Gauge(label: "sinatra.adjustment_factor")
    /// Inferences where the adjustment factor was < 1.0 (positive sentiment → partition boosted).
    static let sinatraBoosts = Counter(label: "sinatra.boosts_total")
    /// Inferences where the adjustment factor was > 1.0 (negative sentiment → partition demoted).
    static let sinatraDemotions = Counter(label: "sinatra.demotions_total")

    // MARK: - LLM provider
    /// Total LLM API requests dispatched (labelled by model).
    static let llmRequests = Counter(label: "provider.llm_requests_total")
    /// End-to-end LLM API round-trip time (milliseconds, labelled by model).
    static let llmDuration = Timer(label: "provider.llm_request_duration")

    // MARK: - Embedding provider
    /// Total embedding API requests dispatched.
    static let embeddingRequests = Counter(label: "provider.embedding_requests_total")
    /// End-to-end embedding API round-trip time (milliseconds).
    static let embeddingDuration = Timer(label: "provider.embedding_request_duration")
    /// Number of tasks currently waiting for a concurrency slot (queue depth).
    static let embeddingQueueDepth = Gauge(label: "provider.embedding_queue_depth")
}
