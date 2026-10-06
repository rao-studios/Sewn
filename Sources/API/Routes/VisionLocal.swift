//
//  VisionLocal.swift
//  Sewn
//
//  WHAT: The on-device lane of `/v1/vision/look` and `/v1/vision/ontology` — the same
//        prompts and limits as the hosted lane, answered by `LocalVision`. A request takes
//        it with `provider: local`, the same choice chat makes; a caller with no account
//        can take nothing else.
//  IN:   the two vision routes, after `admittedProvider`
//  OUT:  the route's own response shape
//  PIN:  NEVER HOSTED. Every failure here is an HTTP error the client can read; nothing
//        falls back to Mistral.
//

import Foundation
import Hummingbird
import Logging

/// One on-device answer about one picture, and the model that gave it.
func localVisionAnswer(
    image: String,
    model spec: String?,
    vision: LocalVision,
    logger: Logger,
    instructions: String,
    prompt: String,
    maxTokens: Int,
    temperature: Float,
    followUp: (@Sendable (String) -> String?)? = nil
) async throws -> (text: String, model: LocalVisionModel) {
    let model: LocalVisionModel
    do {
        model = try LocalVisionModel.parse(spec)
    } catch let error as LocalVisionModel.ParseError {
        throw HTTPError(.badRequest, message: error.description)
    }
    guard let data = Data(base64Encoded: image, options: .ignoreUnknownCharacters) else {
        throw HTTPError(.badRequest, message: "image is not base64")
    }
    do {
        let text = try await vision.respond(
            image: data, instructions: instructions, prompt: prompt, model: model,
            maxTokens: maxTokens, temperature: temperature, followUp: followUp)
        return (text, model)
    } catch let error as LocalVisionError {
        logger.error("[VisionLocal] \(error.description)")
        switch error {
        case .unreadableImage, .notASnapshot: throw HTTPError(.badRequest, message: error.description)
        case .emptyAnswer: throw HTTPError(.badGateway, message: "vision model returned no answer")
        }
    } catch let error as ProviderUnavailable {
        logger.error("[VisionLocal] \(error.description)")
        throw HTTPError(.serviceUnavailable, message: error.description)
    } catch {
        logger.error("[VisionLocal] \(model.name): \(error)")
        throw HTTPError(
            .serviceUnavailable,
            message: ProviderUnavailable.localFailed("\(model.name): \(error)").description)
    }
}

/// The ontology on this Mac: the hosted cataloguer's prompt, a larger token budget, and one
/// more turn when the first answer was not a usable JSON object — then the same tolerant
/// parse and caps the hosted lane applies.
func localVisionOntology(
    _ body: VisionOntologyRequest, vision: LocalVision, logger: Logger
) async throws -> VisionOntologyResponse {
    let (answer, model) = try await localVisionAnswer(
        image: body.image, model: body.model, vision: vision, logger: logger,
        instructions: visionOntologySystemPrompt(),
        prompt: visionOntologyUserText(hint: body.hint),
        maxTokens: LocalVision.ontologyMaxTokens, temperature: 0,
        followUp: { first in
            (try? VisionOntologyParser.parse(first, model: "")) == nil ? LocalVision.ontologyRetry : nil
        })
    do {
        return try VisionOntologyParser.parse(answer, model: model.name)
    } catch {
        logger.debug("[VisionLocal] unparsable ontology (\(error)): \(String(answer.prefix(300)))")
        throw HTTPError(.badGateway, message: "vision model returned no ontology")
    }
}
