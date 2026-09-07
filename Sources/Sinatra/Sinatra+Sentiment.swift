//
//  Sinatra+Sentiment.swift
//  sewn-server
//
//  Created by Ritesh Pakala Rao on 1/25/26.
//

import Foundation
import Metrics

// Just in time

extension Sinatra {
    /// JSON Schema for the `record_sentiment` tool — the model is forced to call it,
    /// so field constraints live here instead of a wall of prompt rules.
    static let sentimentSchema: JSONValue = [
        "type": "object",
        "properties": [
            "sentiment": [
                "type": "string",
                "enum": ["positive", "negative", "neutral", "mixed", "ambiguous"],
            ],
            "emotional_tones": [
                "type": "array", "minItems": 1, "maxItems": 4,
                "items": [
                    "type": "string",
                    "enum": ["angry", "frustrated", "satisfied", "confused", "indifferent",
                             "excited", "sarcastic", "curious", "awkward", "anxious",
                             "relieved", "nostalgic", "defensive", "playful", "disappointed",
                             "hopeful", "overwhelmed", "amused", "skeptical", "embarrassed",
                             "proud", "lonely", "grateful", "receptive", "other"],
                ],
            ],
            "reaction_types": [
                "type": "array", "minItems": 1, "maxItems": 4,
                "items": [
                    "type": "string",
                    "enum": ["agreement", "disagreement", "question", "clarification",
                             "emotional", "neutral", "avoidance", "humor", "sarcasm",
                             "deflection", "storytelling", "venting", "praising",
                             "criticizing", "brainstorming", "reminscing", "testing", "other"],
                ],
            ],
            "key_phrases": [
                "type": "array", "minItems": 1, "maxItems": 3,
                "items": ["type": "string"],
                "description": "Short strings quoting or paraphrasing the user's most signal-bearing words.",
            ],
            "confidence": ["type": "number", "minimum": 0, "maximum": 1],
            "notes": ["type": "string", "description": "One sentence max; empty string if nothing to add."],
            "attentiveness": [
                "type": "object",
                "properties": [
                    "referenced_content": [
                        "type": "boolean",
                        "description": "True if the user's message contains a traceable link to the assistant's output.",
                    ],
                    "reference_type": [
                        "type": "string",
                        "enum": ["direct_quote", "paraphrase", "implicit", "none"],
                        "description": "Use none when referenced_content is false.",
                    ],
                    "answered_posed_question": [
                        "type": ["boolean", "null"],
                        "description": "Null only when no question was posed in the assistant response.",
                    ],
                    "building": [
                        "type": "boolean",
                        "description": "True when the user volunteers their own extension of the assistant's idea.",
                    ],
                ],
                "required": ["referenced_content", "reference_type", "answered_posed_question", "building"],
            ],
        ],
        "required": ["sentiment", "emotional_tones", "reaction_types", "key_phrases",
                     "confidence", "notes", "attentiveness"],
    ]
}

extension Sinatra {
    /// Run a sentiment analysis model on chat messages. Determining
    /// whether the User reciprocated certain signals to the previous
    /// assistant message. The `reciprocity` is the sentiment we
    /// are evaluating.
    /// - Parameter data: A `list` of chat messages.
    /// Runs sentiment analysis on `data` to train the GBT model for the *next*
    /// retrieval cycle. Returns a `Gita.TokenLedger` capturing the token usage of
    /// the internal LLM call so the caller can include it in billing.
    ///
    /// Returns an **empty** ledger on all early-exit paths (no LLM was invoked).
    @discardableResult
    /// `provider` is the TURN'S backend. Sentiment and resonance read the
    /// user's words, so they must not reach a vendor the user did not choose:
    /// on-device gates them off (see ModelProvider.run's `background`).
    func prepare(_ data: [ChatMessageRequestData],
                 request: SewnRequest,
                 modelProvider: ModelProvider,
                 provider: LLMProvider = .serverDefault) async throws -> Sinatra.PrepareResult {

        let owner = SewnRegistry.Owner(id: request.ownerId)
        logger.debug("Prepare Sentiment", "⚜️ Starting sentiment analysis for owner: \(owner.id), messages: \(data.count)", service: .sinatra, request: request)

        let registry = self.registry

        // Check user/assistant pair before anything else — resonance extraction
        // requires both sides of the conversation regardless of whether parked data exists.
        guard let lastUserData = data.last(where: { $0.role == .user }),
              let lastAssistantData = data.last(where: { $0.role == .assistant }) else {
            logger.info("No User/Assistant Pair", "⚜️ No user/assistant message pair found — skipping sentiment", service: .sinatra, request: request, flow: .chat)
            return .empty
        }

        let userContent = lastUserData.content
        let assistantContent = lastAssistantData.content

        // Filter 1: Minimum word count — short responses lack enough signal for reliable
        // sentiment assessment and resonance detection.
        let userContentString = userContent.asString ?? ""
        let wordCount = userContentString.split(whereSeparator: \.isWhitespace).count
        guard wordCount >= Sinatra.sentimentContextLimit else {
            logger.info("Short Response", "⚜️ User response too short (\(wordCount) words) — clearing parked, skipping sentiment and training.", service: .sinatra, request: request, flow: .chat)
            if let parked = registry?.parked[owner] {
                let consumedIds = Set(parked.map { $0.id })
                updateRegistry { reg in
                    let remaining = reg.parked[owner]?.filter { !consumedIds.contains($0.id) }
                    reg.parked[owner] = remaining?.isEmpty == false ? remaining : nil
                }
            }
            return .empty
        }

        // Parked data is optional — resonance can be stored even when nothing was retrieved.
        let parked     = registry?.parked[owner]
        let consumedIds = Set(parked?.map { $0.id } ?? [])

        if let parked {
            logger.debug("Prepare Parked Data", "⚜️ Found \(parked.count) parked items for owner: \(owner.id)", service: .sinatra, request: request)
        } else {
            logger.info("No Parked Data", "⚜️ No parked data for: \(owner.id) — resonance-only path (no GBT training)", service: .sinatra, request: request, flow: .chat)
        }

        // --- Pace ---
        // responseLatency approximates the time the user took to reply after the
        // assistant response was ready (parkedAt ≈ end of the previous search).
        // When no parked data exists the latency is unmeasurable; paceScore defaults to 0.
        let assistantString      = assistantContent.asString ?? ""
        let assistantWordCount   = max(1, assistantString.split(whereSeparator: \.isWhitespace).count)
        let parkedAt             = parked?.first?.parkedAt ?? Date()
        let responseLatency      = parked != nil ? Date().timeIntervalSince(parkedAt) : 0.0
        // Normalise: assume ~3 words/second reading pace (0.3 s/word).
        let paceScore            = parked != nil
            ? min(1.0, max(0.0, responseLatency / (Double(assistantWordCount) * 0.3)))
            : 0.0

        // --- Posed question extraction ---
        // Check whether the assistant response ended with or contained a direct question.
        // We pass this to the LLM so it can evaluate whether the user answered it.
        let posedQuestion: String? = extractPosedQuestion(from: assistantString)

        logger.debug("Analyze Sentiment", "⚜️ Analyzing user reaction to assistant message | latency=\(String(format: "%.1f", responseLatency))s assistantWords=\(assistantWordCount) paceScore=\(String(format: "%.2f", paceScore)) posedQuestion=\(posedQuestion != nil ? "yes" : "no")", service: .sinatra, request: request)

        // Ledger accumulates token costs from every internal LLM call in this cycle
        // (resonance extraction + sentiment analysis). Hoisted here so resonance can
        // contribute its cost before the sentinel early-return paths.
        var ledger = Gita.TokenLedger()

        // --- Resonance Gate ---
        // Extract the specific passage the user resonated with before running
        // sentiment analysis or training. A non-nil partition is the primary gate:
        // if no clear resonance is detected, skip GBT+IMBHS training entirely.
        let (resonancePartition, resonanceLedger) = try await extractResonance(
            userContent: userContentString,
            assistantContent: assistantString,
            request: request,
            modelProvider: modelProvider
        )
        ledger.merge(resonanceLedger)

        // Resonance-only path: no parked data means no GBT training, but a detected
        // resonance partition is still returned so the caller can store it. This is the
        // onboarding path — the user personalizes the system before any retrieval has run.
        guard let parked else {
            logger.info("Resonance Only", "⚜️ \(resonancePartition != nil ? "Resonance stored — no parked data, GBT skipped" : "No resonance + no parked data — nothing to do")", service: .sinatra, request: request, flow: .chat)
            return PrepareResult(ledger: ledger, documentStatsUpdates: [:], resonancePartition: resonancePartition)
        }

        guard resonancePartition != nil else {
            // Resonance gate failed — clear consumed parked entries and return.
            // Training is skipped; the resonance ledger is included in billing.
            updateRegistry { reg in
                let remaining = reg.parked[owner]?.filter { !consumedIds.contains($0.id) }
                reg.parked[owner] = remaining?.isEmpty == false ? remaining : nil
            }
            logger.info("Training Gate", "⚜️ SKIP — no resonance detected, GBT+IMBHS training suppressed", service: .sinatra, request: request, flow: .chat)
            return PrepareResult(ledger: ledger, documentStatsUpdates: [:], resonancePartition: nil)
        }

        let posedQuestionContext: String
        if let q = posedQuestion {
            posedQuestionContext = "\n\n**Question posed in assistant response:** \"\(q)\""
        } else {
            posedQuestionContext = ""
        }

        let prompt: String = """
        Analyze the following interaction and reaction from the user:

        **Assistant Response:**
        \(assistantContent)

        **User Response:**
        \(userContent)\(posedQuestionContext)

        Provide the JSON output as specified.
        """

        let systemPrompt: String = """
        You are a sentiment and reaction analyzer. Evaluate the user's response to the \
        assistant message and record your assessment with the record_sentiment tool.
        """

        /* Sentiment Analysis — structured tool call, no prompt-and-parse. */

        logger.debug("Analyze Sentiment", "⚜️ Sending structured sentiment request to LLM (maxTokens=1200)", service: .sinatra, request: request, flow: .chat)

        // Capture token usage so the caller can include this LLM call in billing.
        let sentiment: Sinatra.Sentiment
        do {
            let (value, sinatraUsage): (Sinatra.Sentiment, Requests.Chat.Get.Usage) = try await modelProvider
                .runStructured(prompt,
                               systemPrompt: systemPrompt,
                               toolName: "record_sentiment",
                               toolDescription: "Record the sentiment analysis of the user's response.",
                               schema: Self.sentimentSchema,
                               maxTokens: 1200,
                               provider: provider,
                               logger: logger.base)
            sentiment = value
            ledger.record(
                model: ModelConfig.utilityModel(for: provider),
                promptTokens: sinatraUsage.promptTokens,
                completionTokens: sinatraUsage.completionTokens
            )
        } catch {
            logger.error("Failed to Decode Sentiment", "⚜️ Structured sentiment call failed: \(error)", service: .sinatra, request: request, flow: .chat)
            throw error
        }

        logger.info("Sentiment Result", "⚜️⚜️⚜️⚜️⚜️⚜️⚜️\n \(sentiment.description)", service: .sinatra, request: request, flow: .chat)

        // --- Attentiveness + Engagement Composite ---
        let attentiveness        = sentiment.attentiveness
        let attentivenessScore   = attentiveness?.score ?? 0.0
        let engagementComposite  = (paceScore * 0.4) + (attentivenessScore * 0.6)

        // --- Session boundary ---
        let paceCollapse        = paceScore < 0.1
        let attentivenessReset  = attentivenessScore == 0.0
        let sessionBoundary     = paceCollapse && attentivenessReset
        let boundaryReason: SinatraTrajectorySnapshot.SessionBoundaryReason? = {
            if paceCollapse && attentivenessReset { return .both }
            if paceCollapse                       { return .paceCollapse }
            if attentivenessReset                 { return .attentivenessZero }
            return nil
        }()

        // --- Training gate ---
        // defer: ambiguous + low-confidence — keep parked, wait for more signal next turn.
        if sentiment.sentiment == .ambiguous && sentiment.confidence < 0.5 {
            let snapshot = SinatraTrajectorySnapshot(
                paceScore: paceScore,
                responseLatencySeconds: responseLatency,
                assistantResponseWordCount: assistantWordCount,
                attentivenessScore: attentivenessScore,
                referencedContent: attentiveness?.referencedContent ?? false,
                answeredPosedQuestion: attentiveness?.answeredPosedQuestion,
                building: attentiveness?.building ?? false,
                posedQuestion: posedQuestion,
                engagementComposite: engagementComposite,
                trainingDecision: .defer,
                sessionBoundaryDetected: sessionBoundary,
                sessionBoundaryReason: boundaryReason,
                resonanceExcerpt: resonancePartition?.text,
                resonanceDocumentId: nil
            )
            updateRegistry { reg in
                reg.lastSentiments[owner]   = sentiment
                reg.lastTrajectories[owner] = snapshot
            }
            logger.info("Training Gate", "⚜️ DEFER — ambiguous+low-confidence (composite=\(String(format: "%.2f", engagementComposite))), keeping parked", service: .sinatra, request: request, flow: .chat)
            return PrepareResult(ledger: ledger, documentStatsUpdates: [:], resonancePartition: resonancePartition)
        }

        // discard: composite < 0.2 — one-off pattern, clear parked.
        if engagementComposite < 0.2 {
            let snapshot = SinatraTrajectorySnapshot(
                paceScore: paceScore,
                responseLatencySeconds: responseLatency,
                assistantResponseWordCount: assistantWordCount,
                attentivenessScore: attentivenessScore,
                referencedContent: attentiveness?.referencedContent ?? false,
                answeredPosedQuestion: attentiveness?.answeredPosedQuestion,
                building: attentiveness?.building ?? false,
                posedQuestion: posedQuestion,
                engagementComposite: engagementComposite,
                trainingDecision: .discard,
                sessionBoundaryDetected: sessionBoundary,
                sessionBoundaryReason: boundaryReason,
                resonanceExcerpt: resonancePartition?.text,
                resonanceDocumentId: nil
            )
            updateRegistry { reg in
                let remaining = reg.parked[owner]?.filter { !consumedIds.contains($0.id) }
                reg.parked[owner] = remaining?.isEmpty == false ? remaining : nil
                reg.lastSentiments[owner]   = sentiment
                reg.lastTrajectories[owner] = snapshot
            }
            logger.info("Training Gate", "⚜️ DISCARD — composite=\(String(format: "%.2f", engagementComposite)) below threshold (paceScore=\(String(format: "%.2f", paceScore)) attentiveness=\(String(format: "%.2f", attentivenessScore)))\(sessionBoundary ? " SESSION BOUNDARY: \(boundaryReason?.rawValue ?? "")" : "")", service: .sinatra, request: request, flow: .chat)
            return PrepareResult(ledger: ledger, documentStatsUpdates: [:], resonancePartition: nil)
        }

        // train or light-train based on composite band.
        let trainingDecision: SinatraTrajectorySnapshot.TrainingDecision = engagementComposite >= 0.5 ? .train : .lightTrain
        // Light-train: scale the sentiment weight down by the composite so one-off-adjacent
        // interactions contribute weakly rather than polluting the full signal.
        let baseWeight       = sentiment.calculateWeight()
        let effectiveWeight  = trainingDecision == .lightTrain ? baseWeight * engagementComposite : baseWeight

        logger.info("Training Gate", "⚜️ \(trainingDecision == .train ? "TRAIN" : "LIGHT TRAIN") — composite=\(String(format: "%.2f", engagementComposite)) weight=\(String(format: "%.4f", baseWeight))→\(String(format: "%.4f", effectiveWeight))", service: .sinatra, request: request, flow: .chat)

        /* Compile DataSet */

        var updatedRegistry = registry ?? SinatraRegistry()

        var collector = updatedRegistry.collectors[owner] ?? RetrievalDataCollector()
        collector.logger = logger

        // Clear dataset if feature dimension changed (e.g. after upgrading from 12 to 14 features).
        // The model is also cleared so the next training cycle starts fresh on the new feature space.
        var dataSet = updatedRegistry.dataSets[owner] ?? DataSet(
            dataType: .Regression,
            inputDimension: RetrievalDataCollector.featureVectorDimension,
            outputDimension: 1
        )
        if dataSet.inputDimension != RetrievalDataCollector.featureVectorDimension {
            logger.info("Dataset Reset", "⚜️ Feature dimension changed (\(dataSet.inputDimension) → \(RetrievalDataCollector.featureVectorDimension)) — clearing dataset and model", service: .sinatra, request: request, flow: .chat)
            dataSet = DataSet(
                dataType: .Regression,
                inputDimension: RetrievalDataCollector.featureVectorDimension,
                outputDimension: 1
            )
            updatedRegistry.models.removeValue(forKey: owner)
        }

        let responseLength = assistantString.count
        SewnMetrics.sinatraSentimentWeight.record(effectiveWeight)
        SewnMetrics.sinatraSentimentConfidence.record(sentiment.confidence)
        logger.debug("Sentiment Weight", "⚜️ base=\(String(format: "%.4f", baseWeight)) effective=\(String(format: "%.4f", effectiveWeight)) confidence=\(sentiment.confidence) responseLength=\(responseLength)", service: .sinatra, request: request)

        /* Record the interaction in the RetrievalDataCollector, generate a feature vector for each
           parked item, and add it to the dataset with the effective weight as the target label.
           Performance updates (retrievalCount, sentimentSum, lastRetrieved) are accumulated in
           `localDocStats` and returned to the caller for persistence in SewnRegistry.documentStats. */

        var featureVectorsGenerated = 0
        var featureVectorsSkipped = 0
        var newPoints: [(input: [Double], target: Double, label: String)] = []
        var localDocStats: [DocumentID: Sewn.DocumentStats] = [:]

        for parkedItem in parked {
            // Key by documentId so stats are persisted to the correct DocumentStats
            // entry in SewnRegistry. The partitionId (parkedItem.id) is tracked
            // inside partitionRetrievalCount and partitionSentiments for per-partition granularity.
            let docKey      = parkedItem.documentId.isEmpty ? parkedItem.id : parkedItem.documentId
            let partitionId = parkedItem.id
            let updatedStats = collector.recordInteraction(
                parked: parkedItem,
                sentiment: sentiment,
                responseLength: responseLength,
                effectiveWeight: effectiveWeight,
                paceScore: paceScore,
                attentivenessScore: attentivenessScore,
                existingStats: localDocStats[docKey],
                request: request
            )
            localDocStats[docKey] = updatedStats

            if let featureVector = collector.generateFeatureVector(
                partitionId: partitionId,
                documentId: docKey,
                documentStats: localDocStats,
                request: request
            ) {
                try dataSet.addDataPoint(
                    input: featureVector,
                    output: [effectiveWeight],
                    label: parkedItem.id
                )
                newPoints.append((input: featureVector, target: effectiveWeight, label: parkedItem.id))
                featureVectorsGenerated += 1
                logger.info("Train", "⚜️ [TRAIN] partition=\(partitionId) doc=\(docKey) weight=\(String(format: "%.4f", effectiveWeight)) vec=✓ dataSet=\(dataSet.size)",
                            service: .gbtTraining, request: request, flow: .frank(partitionId: partitionId))
            } else {
                featureVectorsSkipped += 1
                logger.info("Train", "⚜️ [TRAIN] partition=\(partitionId) doc=\(docKey) weight=\(String(format: "%.4f", effectiveWeight)) vec=✗ (history<20)",
                            service: .gbtTraining, request: request, flow: .frank(partitionId: partitionId))
            }
        }

        SewnMetrics.sinatraFeatureVectorsGenerated.increment(by: featureVectorsGenerated)
        SewnMetrics.sinatraFeatureVectorsSkipped.increment(by: featureVectorsSkipped)
        logger.info("Record Interaction", "⚜️ Recorded \(parked.count) interactions | featureVectors: \(featureVectorsGenerated) generated, \(featureVectorsSkipped) skipped | dataSet size: \(dataSet.size)", service: .sinatra, request: request, flow: .chat)

        updatedRegistry.collectors[owner]     = collector
        updatedRegistry.dataSets[owner]       = dataSet
        updatedRegistry.lastSentiments[owner] = sentiment

        // --- GBT Training ---
        // Full retrain from scratch on each cycle. At ≤200 points × 12 features × 50 trees,
        // O(n·d·T) training is sub-millisecond — no incremental update machinery needed.
        // Adaptive hyperparameters are selected inside GBTModel.train(data:) based on dataset size.
        let requiredSize = RetrievalDataCollector.minimumTrainingSamples
        if dataSet.size >= requiredSize && !newPoints.isEmpty {
            var gbtModel = updatedRegistry.models[owner] ?? createModel()
            logger.debug("Prepare GBT", "⚜️ Training GBT with \(dataSet.size) datapoints", service: .gbtTraining, request: request)
            let trainStart = Date()
            gbtModel.train(data: dataSet)
            let trainElapsedNs = UInt64(max(0, Date().timeIntervalSince(trainStart) * 1_000_000_000))
            SewnMetrics.sinatraTrainingDuration.recordNanoseconds(trainElapsedNs)
            let tier: String
            switch dataSet.size {
            case ..<30: tier = "small"
            case 30..<80: tier = "medium"
            default: tier = "full"
            }
            Counter(label: "sinatra.training_runs_total", dimensions: [("tier", tier)]).increment()
            SewnMetrics.sinatraDatasetSize.record(Double(dataSet.size))
            SewnMetrics.sinatraModelTrees.record(Double(gbtModel.totalTrees))
            SewnMetrics.sinatraModelInitialPrediction.record(gbtModel.initialPrediction)
            updatedRegistry.models[owner] = gbtModel
            logger.info("GBT Result", "⚜️ Trained for owner: \(owner.id), trees: \(gbtModel.totalTrees), dataSet: \(dataSet.size)pts", service: .gbtTraining, request: request, flow: .chat)

            // --- IMBHS: Harmony Search Period Tuning ---
            // Increment the generation counter after each successful training cycle.
            // Every `cadence` cycles after `warmup`, run one IMBHS improvisation step
            // to search for better indicator period configurations.
            var harmonyMemory = updatedRegistry.harmonyMemories[owner] ?? HarmonyMemory()
            harmonyMemory.incrementGeneration()

            // Warmup heartbeat: log every 5 cycles during warmup so progress is visible.
            // After warmup, IMBHS runs every cadence cycles — no idle cycles exist.
            if !harmonyMemory.shouldRun && harmonyMemory.generation % 5 == 0 {
                logger.debug("IMBHS", "⚜️ warming up \(harmonyMemory.generation)/\(HarmonyMemory.warmup) │ active [\(harmonyMemory.activePeriods.logDescription)]", service: .gbtTraining, request: request)
            }

            if harmonyMemory.shouldRun {
                // Capture state before update() for logging and before/after comparison
                let prevActivePeriods = harmonyMemory.activePeriods
                let prevActiveFit = zip(harmonyMemory.harmonies, harmonyMemory.fitness)
                    .first(where: { $0.0 == harmonyMemory.activePeriods })?.1

                let candidate      = harmonyMemory.improvise()
                let candidateFit   = collector.evaluateFitness(periods: candidate, model: gbtModel, documentStats: localDocStats)
                let periodsChanged = harmonyMemory.update(candidate: candidate, candidateFitness: candidateFit)
                SewnMetrics.sinatraImbhsGeneration.record(Double(harmonyMemory.generation))
                if candidateFit.isFinite {
                    SewnMetrics.sinatraImbhsFitness.record(candidateFit)
                }
                if periodsChanged {
                    SewnMetrics.sinatraImbhsTunings.increment()
                }

                // Build a single summary line covering schedule state, candidate, HM, and outcome
                let hmEvaluated = harmonyMemory.fitness.filter { $0.isFinite }.count
                let hmBestFit   = harmonyMemory.fitness.filter { $0.isFinite }.min()
                let fitStr      = candidateFit.isFinite ? String(format: "%.4f", candidateFit) : "∞"
                let bestStr     = hmBestFit.map { String(format: "%.4f", $0) } ?? "∞"
                let resultStr: String
                if periodsChanged {
                    resultStr = "→ PERIOD CHANGE"
                } else if let af = prevActiveFit, af.isFinite, candidateFit.isFinite {
                    let deltaPct = (af - candidateFit) / af * 100
                    resultStr = "→ no change (Δ\(String(format: "%+.2f", deltaPct))%)"
                } else {
                    resultStr = "→ no change"
                }
                logger.debug("IMBHS", "⚜️ gen=\(harmonyMemory.generation) PAR=\(String(format: "%.2f", harmonyMemory.currentPAR)) BW=\(harmonyMemory.currentBW) │ candidate [\(candidate.logDescription)] fit=\(fitStr) │ HM \(hmEvaluated)/\(HarmonyMemory.memorySize) best=\(bestStr) │ \(resultStr)", service: .gbtTraining, request: request)

                if periodsChanged {
                    // Active periods changed — rebuild dataset from history with new periods,
                    // then retrain. With GBT, this is two cheap operations (no trainer to discard).
                    logger.info("IMBHS Period Change", "⚜️ [\(prevActivePeriods.logDescription)] → [\(harmonyMemory.activePeriods.logDescription)]", service: .gbtTraining, request: request, flow: .chat)

                    collector.applyPeriods(harmonyMemory.activePeriods)
                    let freshDataSet = collector.buildDataSet(documentStats: localDocStats)
                    gbtModel.train(data: freshDataSet)

                    updatedRegistry.models[owner]   = gbtModel
                    updatedRegistry.dataSets[owner] = freshDataSet

                    logger.info("IMBHS Retrained", "⚜️ trees=\(gbtModel.totalTrees) dataSet=\(freshDataSet.size)pts │ active [\(harmonyMemory.activePeriods.logDescription)]", service: .gbtTraining, request: request, flow: .chat)
                }
            }

            updatedRegistry.harmonyMemories[owner] = harmonyMemory

        } else if dataSet.size < requiredSize {
            logger.debug("Skipped GBT", "⚜️ Skipping GBT training: dataSet size \(dataSet.size) < required \(requiredSize), interactionHistory: \(collector.interactionHistoryCount)", service: .gbtTraining, request: request)
        }

        SewnMetrics.sinatraParked.record(0)

        updatedRegistry.lastTrajectories[owner] = SinatraTrajectorySnapshot(
            paceScore: paceScore,
            responseLatencySeconds: responseLatency,
            assistantResponseWordCount: assistantWordCount,
            attentivenessScore: attentivenessScore,
            referencedContent: attentiveness?.referencedContent ?? false,
            answeredPosedQuestion: attentiveness?.answeredPosedQuestion,
            building: attentiveness?.building ?? false,
            posedQuestion: posedQuestion,
            engagementComposite: engagementComposite,
            trainingDecision: trainingDecision,
            sessionBoundaryDetected: sessionBoundary,
            sessionBoundaryReason: boundaryReason,
            resonanceExcerpt: resonancePartition?.text,
            resonanceDocumentId: resonancePartition?.documentId
        )

        // Atomically write only the fields prepare() modified. Parked data is
        // filtered by consumedIds — any parks appended by this turn's search
        // during the LLM call are preserved rather than clobbered by a full
        // registry overwrite.
        updateRegistry { reg in
            reg.collectors[owner]       = updatedRegistry.collectors[owner]
            reg.dataSets[owner]         = updatedRegistry.dataSets[owner]
            reg.models[owner]           = updatedRegistry.models[owner]
            reg.harmonyMemories[owner]  = updatedRegistry.harmonyMemories[owner]
            reg.lastSentiments[owner]   = updatedRegistry.lastSentiments[owner]
            reg.lastTrajectories[owner] = updatedRegistry.lastTrajectories[owner]
            let remaining = reg.parked[owner]?.filter { !consumedIds.contains($0.id) }
            reg.parked[owner] = remaining?.isEmpty == false ? remaining : nil
        }

        logger.info("Updated Registry", "⚜️ Compiled \(parked.count) parked items for owner: \(owner.id), dataSet size: \(dataSet.size)", service: .sinatra, request: request, flow: .chat)

        return PrepareResult(ledger: ledger, documentStatsUpdates: localDocStats, resonancePartition: resonancePartition)
    }

    /// Extracts the last question sentence from an assistant response string.
    /// Returns nil when no sentence ending with `?` is found.
    func extractPosedQuestion(from text: String) -> String? {
        let questionPattern = try? NSRegularExpression(pattern: #"[^.!?\n]+\?"#)
        let range = NSRange(text.startIndex..., in: text)
        let matches = questionPattern?.matches(in: text, range: range) ?? []
        guard let last = matches.last,
              let swiftRange = Range(last.range, in: text) else { return nil }
        let candidate = String(text[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? nil : candidate
    }

    /// Handles several common LLM JSON malformations:
    /// - Parenthetical comments: "value" (some comment)
    /// - Inline remarks after values: "value" -- some note
    /// - Trailing text before comma/bracket: "value" some words,
    func cleanLLMJSON(_ input: String) -> String {
        var result = input

        // Pattern 1: Remove parenthetical comments after quoted strings
        // e.g. "value" (some comment) -> "value"
        if let regex = try? NSRegularExpression(
            pattern: #"("(?:[^"\\]|\\.)*")\s*\([^)\n]*\)"#
        ) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "$1")
        }

        // Pattern 2: Remove double-dash inline remarks after quoted strings
        // e.g. "value" -- some remark -> "value"
        if let regex = try? NSRegularExpression(
            pattern: #"("(?:[^"\\]|\\.)*")\s*--[^\n,\]]*"#
        ) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "$1")
        }

        // Pattern 3: Remove trailing non-JSON text after quoted strings
        // e.g. "value" some trailing words -> "value"
        // Requires at least one space/tab (not newline) before the trailing text, and
        // the trailing text must not begin with a JSON structural character (: , ] } " {)
        if let regex = try? NSRegularExpression(
            pattern: #"("(?:[^"\\]|\\.)*")[ \t]+[^,\]}\n:"{][^\n,\]}{":]*"#
        ) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "$1")
        }

        return result
    }
}

private extension String {
    func sanitizeMarkdownJSON() -> String {
        var result = self

        // Remove opening fence with optional language specifier
        if let range = result.range(of: "^```[a-zA-Z]*\\n?", options: .regularExpression) {
            result.removeSubrange(range)
        }

        // Remove closing fence
        if let range = result.range(of: "\\n?```$", options: .regularExpression) {
            result.removeSubrange(range)
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

