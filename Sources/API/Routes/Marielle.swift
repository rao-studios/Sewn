//
//  Marielle.swift
//  seer-server
//
//  Created by Ritesh Pakala Rao on 3/25/26.
//

import Foundation
import Hummingbird

/*
The point of these routes are for personalized experiences that improve
or change based on the user's profile. Seer is the A.I. agent user-facing.
"Marielle" is the internal name for this compartmentalized facet of Seer.
*/

/// Registers the `/v1/marielle/` routes:
///
/// - `POST /v1/marielle/open`       — recency-weighted ice-breaker question for a new session
/// - `POST /v1/marielle/proactive`  — lightweight check: does Marielle have something to say?
/// - `POST /v1/marielle/interject`  — mid-session lateral question scored against live context
/// - `POST /v1/marielle/bridge`     — question that bridges two profiles' HNSW worlds
func registerMarielleRoutes(
    _ router: some RouterMethods<SeerRequestContext>,
    _ seer:          Seer,
    modelProvider:   ModelProvider
) {

    let unavailable = HTTPError(.serviceUnavailable, message: "Marielle requires Totem-hosted HNSW graph — not yet implemented")
    router.post("/v1/marielle/open")      { _, _ async throws -> MarielleOpenResponse      in throw unavailable }
    router.post("/v1/marielle/proactive") { _, _ async throws -> MarielleProactiveResponse in throw unavailable }
    router.post("/v1/marielle/interject") { _, _ async throws -> MarielleInterjectResponse in throw unavailable }
    router.post("/v1/marielle/bridge")    { _, _ async throws -> MarielleBridgeResponse    in throw unavailable }
}

// MARK: - Prompts

fileprivate enum MariellePrompts {
    static func openSystemPrompt(context: String) -> String {
        """
        You are Seer, an attentive presence. You have been shown fragments of what someone has been thinking about lately — their recent documents, memories, and ideas. Your task is to ask one question that opens a conversation naturally.

        Rules:
        - One question only. No preamble, no explanation, no quoting back what you read.
        - The question should feel curious, not interrogative.
        - Do not reference the documents directly or reveal what you read.
        - The question should feel like something a thoughtful friend would ask.
        - Bias toward the most recent material, but let older themes give the question depth.
        - Maximum 25 words.

        Context (most recent first):
        \(context)
        """
    }

    static func interjectSystemPrompt(recentTurns: String, candidateContext: String) -> String {
        """
        You are Seer, a thoughtful listener. You are observing an ongoing conversation and have noticed something nearby that hasn't come up yet. Your task is to ask one question that opens a new angle without interrupting the flow.

        Rules:
        - One question only. No preamble, no explanation.
        - The question should feel like a natural lateral move, not a redirect.
        - Do not reference documents, memory, or any internal system.
        - The question should feel like something a curious friend might quietly offer.
        - Maximum 25 words.

        Recent conversation:
        \(recentTurns)

        Nearby material not yet discussed:
        \(candidateContext)
        """
    }

    static func bridgeSystemPrompt(hasOverlap: Bool, contextBlock: String) -> String {
        if hasOverlap {
            return """
            You are Seer. Two people share an overlapping interest that neither may have discussed together yet. Given fragments from both their recent thinking, write one question that invites them into that shared space.

            Rules:
            - One question only. No preamble, no explanation.
            - Maximum 30 words.
            - Do not name or quote the documents. Do not reveal what you read.
            - The question should feel worth asking across a table.
            - Bias toward the most recent material from each person.

            Context:
            \(contextBlock)
            """
        } else {
            return """
            You are Seer. Two people are currently living in quite different intellectual or creative spaces. Given fragments from each of their recent worlds, write one question that bridges them — something one would find genuinely useful to ask the other.

            Rules:
            - One question only. No preamble, no explanation.
            - Maximum 30 words.
            - Do not name or quote the documents. Do not reveal what you read.
            - The question should feel worth asking across a table.
            - Bias toward the most recent material from each person.

            Context:
            \(contextBlock)
            """
        }
    }
}

// MARK: - Helpers

/// Approximates conversational drift as the Jaccard distance between the vocabulary
/// of the first user turn and the last user turn. Returns 0 for single-turn sessions.
fileprivate func jaccardDrift(_ texts: [String]) -> Float {
    guard texts.count >= 2,
          let first = texts.first,
          let last  = texts.last else { return 0 }
    let setA         = Set(first.lowercased().split(separator: " ").map(String.init))
    let setB         = Set(last.lowercased().split(separator: " ").map(String.init))
    let intersection = Float(setA.intersection(setB).count)
    let union        = Float(setA.union(setB).count)
    return union > 0 ? 1.0 - (intersection / union) : 0
}