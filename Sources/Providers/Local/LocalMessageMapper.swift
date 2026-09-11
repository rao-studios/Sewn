//
//  LocalMessageMapper.swift
//  Sewn
//
//  WHAT: Role mapping and tool rendering for the on-device model. Pure — no
//        MLX import — so it is unit-tested without a GPU.
//  PIN:  Mistral-family Jinja templates demand strict user/assistant
//        alternation and reject a bare "tool" role, so consecutive same-role
//        turns merge rather than being sent as-is.
//

import Foundation

enum LocalMessageMapper {

    struct Turn: Equatable, Sendable {
        var isUser: Bool
        var text: String
    }

    /// Collapse a role-tagged transcript into strict alternation, dropping
    /// empty assistant turns the way the hosted paths already do.
    static func alternating(_ messages: [Requests.Chat.Get.Message]) -> [Turn] {
        var mapped: [Turn] = []
        for message in messages {
            let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let isUser = message.role != ChatMessageRequestRole.assistant.rawValue
            if let last = mapped.last, last.isUser == isUser {
                mapped[mapped.count - 1].text += "\n\n" + text
            } else {
                mapped.append(Turn(isUser: isUser, text: text))
            }
        }
        return mapped
    }

    /// A tool roster spelled into the system prompt. Frigate's processor
    /// parses the native wrapper, but a small Mistral narrates the call in
    /// markdown unless the contract is stated.
    static func systemText(_ system: String?, tools: [Requests.Chat.Get.Tool]?) -> String {
        var text = system ?? ""
        guard let tools, !tools.isEmpty else { return text }
        let roster = tools
            .map { "\($0.function.name) — \($0.function.description ?? "")" }
            .joined(separator: "\n")
        text += """


        Your Skills, by exact name (never invent other names):
        \(roster)

        To perform an action, respond with ONLY this exact format on its own — \
        no other words, no code fences:
        <tool_call>{"name": "tool_name", "arguments": {"param": "value"}}</tool_call>
        For plain conversation, answer normally without tags.
        """
        return text
    }

    /// Render one tool as Frigate's ToolSpec — the OpenAI-style function shape
    /// its `Tool.init` builds. Sewn's `JSONValue` parameters go through
    /// Foundation so no MLX type is named here.
    static func toolSpec(from tool: Requests.Chat.Get.Tool) -> [String: any Sendable] {
        var parameters: [String: any Sendable] = [
            "type": "object",
            "properties": [String: any Sendable](),
            "required": [String](),
        ]
        if let declared = tool.function.parameters,
           let data = try? JSONEncoder().encode(declared),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let sendable = object as? [String: any Sendable] {
            parameters = sendable
        }
        return [
            "type": "function",
            "function": [
                "name": tool.function.name,
                "description": tool.function.description ?? "",
                "parameters": parameters,
            ] as [String: any Sendable],
        ]
    }
}
