//
//  ChatRequests.swift
//  Seer
//
//  Created by Ritesh Pakala on 10/28/25.
//

import Foundation

extension Requests {
    struct Chat {}
}

extension Requests.Chat {
    struct Get: NetworkRequest {
        typealias Response = Result

        var path: String { "v1/chat/completions" }
        var method: RequestMethod { .post }

        let model: String
        let messages: [Message]
        let maxTokens: Int?
        let temperature: Double?
        let topP: Double?
        let stream: Bool?
        let stop: [String]?

        enum CodingKeys: String, CodingKey {
            case model
            case messages
            case maxTokens = "max_tokens"
            case temperature
            case topP = "top_p"
            case stream
            case stop
        }

        init(
            model: String,
            messages: [Message],
            maxTokens: Int? = nil,
            temperature: Float = 0.4,
            topP: Float = 0.9,
            stream: Bool = false,
            stop: [String]? = nil
        ) {
            self.model = model
            self.messages = messages
            self.maxTokens = maxTokens
            self.temperature = Double(temperature)
            self.topP = Double(topP)
            self.stream = stream
            self.stop = stop
        }

        // MARK: Response Model (Mistral-compatible)
        struct Result: Codable {
            let id: String
            let object: String
            let created: Int
            let model: String
            let choices: [Choice]
            let usage: Usage

            enum CodingKeys: String, CodingKey {
                case id
                case object
                case created
                case model
                case choices
                case usage
            }
        }

        struct Usage: Codable {
            let promptTokens: Int
            let completionTokens: Int
            let totalTokens: Int

            enum CodingKeys: String, CodingKey {
                case promptTokens = "prompt_tokens"
                case completionTokens = "completion_tokens"
                case totalTokens = "total_tokens"
            }
            
            var description: String {
                """
                Prompt Tokens: \(promptTokens)
                Completion Tokens: \(completionTokens)
                Total Tokens: \(totalTokens)
                """
            }
        }

        struct Choice: Codable {
            let index: Int
            let message: Message
            let finishReason: String

            enum CodingKeys: String, CodingKey {
                case index
                case message
                case finishReason = "finish_reason"
            }
        }

        struct Message: Codable {
            let role: String
            let toolCalls: [String]?
            let content: String
            
            enum CodingKeys: String, CodingKey {
                case role
                case toolCalls = "tool_calls"
                case content
            }
            
            init(role: String,
                 toolCalls: [String]?,
                 content: String) {
                self.role = role
                self.toolCalls = toolCalls
                self.content = content
            }
            
            init(role: String,
                 content: String) {
                self.role = role
                self.toolCalls = nil
                self.content = content
            }
        }
    }
}
