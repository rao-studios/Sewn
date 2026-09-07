//
//  Summarize.swift
//  sewn-server
//
//  Created by Ritesh Pakala Rao on 1/10/26.
//

import Foundation
import Hummingbird

func registerSummarizeRoute(_ router: some RouterMethods<SewnRequestContext>,
                            _ sewn: Sewn,
                            modelProvider: ModelProvider,
                            isAPI: Bool = false) {
    router.post("/v1/tools/summarize") { request, context async throws -> SummarizeResponse in
        let summarizeRequest = try await request.decode(as: SummarizeRequest.self, context: context)
        let logger = context.logger
        let toolReqId = "tools-summarize-\(UUID().uuidString)"
        logger
            .info(
                "Received tools-summarize request (ID: \(toolReqId)) for owner: \(summarizeRequest.sewn.ownerId)"
            )
        
        let systemPrompt: String = """
        You are an advanced language model. Your task is to summarize the provided content in three parts. Write as if the user wrote the summary from their perspective.

        ### Instructions:
        1. **Title**: A concise title, 7 words max. No quotes, no prefix labels, no markdown.
        2. **Thesis**: A 1-2 sentence thesis encapsulating the core argument or message.
        3. **Key Points**: 3-5 key points as concise, self-contained sentences.

        ### Output Format (follow exactly):
        <title>
        [title text only, no formatting]
        </title>
        <thesis>
        [1-2 sentence thesis]
        </thesis>
        <key_points>
        1. [Key Point 1]
        2. [Key Point 2]
        3. [Key Point 3]
        4. [Key Point 4] (if applicable)
        5. [Key Point 5] (if applicable)
        </key_points>

        ### Rules:
        - Use ONLY the XML-style tags shown above. No markdown headers, no bold, no extra labels.
        - The title must be plain text with no leading/trailing whitespace.
        - Do not include the word "Title:" or any prefix inside the <title> tags.
        """
        
        let output: String = try await StandaloneGeneration
            .runLLM(
                summarizeRequest.content,
                systemPrompt: systemPrompt,
                maxTokens: 777,
                modelProvider: modelProvider,
                logger: context.logger
            ) ?? ""
            
        return .init(result: output)
    }
}
