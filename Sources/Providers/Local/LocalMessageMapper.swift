//
//  LocalMessageMapper.swift
//  Sewn
//
//  WHAT: Role mapping and tool rendering for the on-device model. Pure — no
//        MLX import — so it is unit-tested without a GPU.
//  PIN:  Mistral-family Jinja templates demand strict user/assistant
//        alternation and reject a bare "tool" role, so consecutive same-role
//        turns merge rather than being sent as-is. The same templates glue the
//        system prompt onto the front of the LAST user message
//        ("[INST] {system}\n\n{user}[/INST]"). Fencing it as "standing
//        instructions" was tried against Nemo 12B on Mary's prompt (2026-09-24)
//        and did not stop it addressing the user by the persona's name; it added
//        "Mary:" speaker labels instead, so the text goes in unmarked.
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

    /// The system prompt and the turns a chat template will accept.
    ///
    /// Mistral's template (and most instruct templates) require the first message
    /// after the system prompt to be the user's, and reject the whole request
    /// otherwise. A history can open on the assistant: an unprompted remark made
    /// before the user spoke, or a cut that starts on a reply. Those opening
    /// remarks move into the system prompt as what was said before the user's first
    /// message, so the model still knows it said them.
    static func conversation(
        system: String?, messages: [Requests.Chat.Get.Message], tools: [Requests.Chat.Get.Tool]?
    ) -> (system: String, turns: [Turn]) {
        var turns = alternating(messages)
        var opening: [String] = []
        while let first = turns.first, !first.isUser {
            opening.append(first.text)
            turns.removeFirst()
        }
        var text = systemText(system, tools: tools)
        if !opening.isEmpty {
            if !text.isEmpty { text += "\n\n" }
            text += "Before the user's first message here, you said:\n" + opening.joined(separator: "\n\n")
        }
        return (text, turns)
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
