//
//  Seer+AutoMemory.swift
//  Seer
//
//  Created by Ritesh Pakala on 3/21/26.
//

import Foundation

extension Seer {
    /// An individual signal that can contribute to firing an auto-memory snapshot.
    /// Add new cases here as additional trigger sources are introduced.
    enum AutoMemoryTrigger: Hashable {
        /// Fires every time the user message count crosses a multiple of `threshold`.
        case messageCount(threshold: Int = 7)
        /// Fires when Sinatra detects a session boundary (pace + attentiveness collapse),
        /// indicating a topic shift or re-entry.
        case topicChange
    }

    /// Determines how the active triggers are evaluated.
    ///
    /// - `any`:  snapshot fires when *at least one* active trigger fires (OR).
    /// - `all`:  snapshot fires only when *every* active trigger fires simultaneously (AND).
    ///           Scales to any number of triggers — not limited to two.
    enum AutoMemoryPolicyMode: Equatable {
        case any
        case all
    }

    /// Combines a set of active triggers with an evaluation mode.
    struct AutoMemoryPolicy {
        let triggers: Set<AutoMemoryTrigger>
        let mode: AutoMemoryPolicyMode

        /// Only the message-count threshold fires snapshots.
        static let messageCountOnly = AutoMemoryPolicy(triggers: [.messageCount()], mode: .any)
        /// Only a detected topic change fires snapshots.
        static let topicChangeOnly  = AutoMemoryPolicy(triggers: [.topicChange],    mode: .any)
        /// Either condition alone is sufficient (default).
        static let either           = AutoMemoryPolicy(triggers: [.messageCount(), .topicChange], mode: .any)
        /// All active triggers must fire at the same time.
        static let all              = AutoMemoryPolicy(triggers: [.messageCount(), .topicChange], mode: .all)
    }

    /// Active policy for auto-memory. Swap the preset or supply a custom policy to change behaviour.
    static let autoMemoryPolicy: AutoMemoryPolicy = .either

    /// The stable group label used for all auto-generated memory documents.
    static let autoMemoryGroupLabel: String = "Memory"

    /// Summarises the current conversation, embeds the result, and stores it
    /// as a document inside the user's "Memory" group — going through the full
    /// put → register → index pipeline exactly as a manually embedded document would.
    ///
    /// This function is intentionally fire-and-forget: callers wrap it in an
    /// unstructured `Task { }` so the chat response is never delayed.
    ///
    /// - Parameters:
    ///   - messages: Prior conversation turns (role/content dicts), excluding the most recent user message.
    ///   - recentMessage: The most recent user message string.
    ///   - request: The `SeerRequest` carrying owner metadata.
    ///   - modelProvider: LLM used for summarisation.
    func autoMemorize(
        messages: [[String: Any]],
        recentMessage: String,
        request: SeerRequest,
        modelProvider: ModelProvider
    ) async throws {
        logger.info(
            "Auto Memory",
            "💾 Threshold reached — generating memory snapshot for owner: \(request.ownerId)",
            service: .seer,
            request: request
        )

        // 1. Format the full conversation history into a single block.
        let allMessages = messages + [[
            MessageProcessingKeys.role: ChatMessageRequestRole.user.rawValue,
            MessageProcessingKeys.content: recentMessage,
        ]]

        let formattedHistory = allMessages.compactMap { msg -> String? in
            guard
                let role = msg[MessageProcessingKeys.role] as? String,
                let content = msg[MessageProcessingKeys.content] as? String,
                !content.isEmpty
            else { return nil }
            return "[\(role)]: \(content)"
        }.joined(separator: "\n")

        guard !formattedHistory.isEmpty else {
            logger.debug(
                "Auto Memory",
                "💾 No conversation content to summarise — skipping.",
                service: .seer,
                request: request
            )
            return
        }

        // 2. Summarise using the same prompt as the /v1/tools/summarize endpoint.
        let systemPrompt: String = """
        You are a summarization assistant. Summarize the provided conversation into a concise memory note.

        Format your response as follows:
        - First line: a bold title (e.g. **Title Here**), 7 words max.
        - Followed by a blank line.
        - Then a clear, thorough summary in prose. Capture the key topics, decisions, and takeaways. Write in third person. Be specific and complete — this will be used as a memory of what was discussed.
        """

        guard let summary = try await StandaloneGeneration.runLLM(
            formattedHistory,
            systemPrompt: systemPrompt,
            maxTokens: 777,
            modelProvider: modelProvider,
            logger: baseLogger
        ), !summary.isEmpty else {
            logger.warning(
                "⚠️ Auto Memory: summary generation returned empty — skipping memory snapshot.",
                service: .seer,
                request: request
            )
            return
        }

        let values: [String] = summary.components(separatedBy: .newlines).filter { $0.isEmpty == false }
        
        // 3. Sanitize: strip Markdown syntax and split into individual text values.
        let summaryTexts: [String] = try await Sanitize
            .run(
                values,
                modelProvider: modelProvider,
                logger: baseLogger
            )

        guard !summaryTexts.isEmpty else {
            logger.warning(
                "⚠️ Auto Memory: sanitized summary produced no usable text — skipping memory snapshot.",
                service: .seer,
                request: request
            )
            return
        }

        // 4. Compute document ID; no registry-based dedup (Totem is the source of truth).
        let documentId = computeHash(from: summaryTexts)

        // 5. Generate tags (embedding is handled by the Totem node at index time).
        let memoryTags = TagGenerator.generate(from: summaryTexts).sorted()

        // 6. Build the Memory group (implicitly created by register() if absent).
        let memoryGroup = Seer.Group(
            id: "memory-\(request.ownerId)",
            label: Self.autoMemoryGroupLabel,
            ownerId: request.ownerId,
            documents: []
        )

        let memoryRequest = SeerRequest(
            ownerId: request.ownerId,
            group: memoryGroup,
            aggregate: nil,
            scope: nil,
            totemIds: request.personalTotemId.map { [$0] },
            requestID: nil
        )

        let item = BatchPutItem(id: documentId, texts: summaryTexts, tags: memoryTags,
                               tagsEmbedding: nil, mediaType: .text, update: nil, name: nil, metadata: nil)
        enqueuePut([item], request: memoryRequest)

        logger.info(
            "Auto Memory",
            "💾 Memory snapshot stored (documentId: \(documentId)) for owner: \(request.ownerId)",
            service: .seer,
            request: request
        )
    }
}
