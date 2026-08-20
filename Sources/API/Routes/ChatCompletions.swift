//  Based on: https://github.com/mzbac/swift-mlx-server

import Foundation
import Logging
import Hummingbird

func registerChatCompletionsRoute(
    _ router: some RouterMethods<SeerRequestContext>,
    _ seer: Seer,
    modelProvider: ModelProvider,
    isVLM: Bool = false
) throws {
    router.post("/v1/chat/completions") { request, context async throws -> Response in
        let chatRequest = try await request.decode(as: ChatCompletionRequest.self, context: context)
        if chatRequest.stream == true {
            return try await handleChatStreamCompletions(
                request: request,
                context: context,
                chatRequest: chatRequest,
                seer: seer,
                isVLM: isVLM,
                modelProvider: modelProvider
            )
        } else {
            let chatResp = try await handleChatCompletions(
                request: request,
                context: context,
                chatRequest: chatRequest,
                seer: seer,
                isVLM: isVLM,
                modelProvider: modelProvider
            )
            return try chatResp.response(from: request, context: context)
        }
    }
}

// MARK: - Utility

private func _processTextOnlyMessages(_ chatRequest: ChatCompletionRequest) -> UserInput {
    let messages: [[String: Any]] = chatRequest.messages.map {
        [
            MessageProcessingKeys.role: $0.role,
            MessageProcessingKeys.content: $0.content.asString ?? "",
        ]
    }
    return UserInput(messages: messages)
}

private func _processVLMMessages(_ chatRequest: ChatCompletionRequest) -> ChatResult {
    var allImages: [UserInput.Image] = []
    var allVideos: [UserInput.Video] = []

    let processedMessages: [[String: Any]] = chatRequest.messages.map { message -> [String: Any] in
        switch message.content {
        case .text(let textContent):
            return [
                MessageProcessingKeys.role: message.role,
                MessageProcessingKeys.content: textContent,
            ]

        case .fragments(let fragments):
            let imageFragments = fragments.filter { $0.type == MessageProcessingKeys.imageType }
            let videoFragments = fragments.filter { $0.type == MessageProcessingKeys.videoType }

            let images = imageFragments.compactMap { fragment in
                fragment.imageUrl.map { UserInput.Image.url($0) }
            }
            allImages.append(contentsOf: images)

            let videos = videoFragments.compactMap { fragment in
                fragment.videoUrl.map { UserInput.Video.url($0) }
            }
            allVideos.append(contentsOf: videos)

            if !images.isEmpty || !videos.isEmpty {
                var contentFragments: [[String: Any]] = []

                fragments.forEach { fragment in
                    if fragment.type == MessageProcessingKeys.text, let text = fragment.text {
                        contentFragments.append([
                            MessageProcessingKeys.type: MessageProcessingKeys.text,
                            MessageProcessingKeys.text: text,
                        ])
                    }
                }

                contentFragments.append(
                    contentsOf: imageFragments.map { _ in
                        [MessageProcessingKeys.type: MessageProcessingKeys.imageType]
                    })
                contentFragments.append(
                    contentsOf: videoFragments.map { _ in
                        [MessageProcessingKeys.type: MessageProcessingKeys.videoType]
                    })

                return [
                    MessageProcessingKeys.role: message.role,
                    MessageProcessingKeys.content: contentFragments,
                ]
            } else {
                return [
                    MessageProcessingKeys.role: message.role,
                    MessageProcessingKeys.content: message.content.asString ?? "",
                ]
            }

        case .none:
            return [MessageProcessingKeys.role: message.role, MessageProcessingKeys.content: ""]
        }
    }

    var userInput = UserInput(messages: processedMessages, images: allImages, videos: allVideos)

    if let resize = chatRequest.resize, !resize.isEmpty {
        let size: CGSize
        if resize.count == 1 {
            let value = resize[0]
            size = CGSize(width: value, height: value)
        } else if resize.count >= 2 {
            let v0 = resize[0]
            let v1 = resize[1]
            size = CGSize(width: v0, height: v1)
        } else {
            size = CGSize(width: 0, height: 0)
        }

        if size.width != 0 && size.height != 0 {
            userInput.processing.resize = size
        }
    }

    // TODO: When audio-visual aggregation begins.
    return .init(input: userInput, references: [], contribution: nil, tone: nil, autoMemory: false)
}

/// Processes a user message using seer. Seer handles contribution tracking.
/// - Parameters:
///   - chatRequest: The completion request.
///   - seer: The isntance of Seer.
///   - embeddingModelProvider: The embeddingModel, if nil Mistral API is used.
///   - isVLM: VLM flag.
/// - Throws: Errors.
/// - Returns: ChatResult with `UserInput`.
func _processUserMessages(
    _ chatRequest: ChatCompletionRequest,
    _ seer: Seer,
    modelProvider: ModelProvider,
    isVLM: Bool,
    seerRequest: SeerRequest? = nil
) async throws -> ChatResult {
    if isVLM {
        return _processVLMMessages(chatRequest)
    } else {
        return try await seer
            .handleChat(
                request: chatRequest,
                modelProvider: modelProvider,
                seerRequest: seerRequest,
                queryExpansion: chatRequest.resonate ?? false
            )
    }
}
