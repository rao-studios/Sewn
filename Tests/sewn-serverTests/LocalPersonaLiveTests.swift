//
//  LocalPersonaLiveTests.swift
//  sewn-serverTests
//
//  Does the on-device model know who is who? It used to call the user by
//  its own name ("Thanks, Mary!"). Twenty short voice-style utterances run
//  through the real model with the real persona, instructions and prompt
//  assembly, several seeds each, per prompt variant; replies that use the
//  assistant's name as a form of address are counted and printed.
//
//  Run (the fixtures come from Ambient's `--probe-prompt`):
//    SEWN_LOCAL_PERSONA_TESTS=1 \
//    SEWN_PERSONA_BEFORE=before.json [SEWN_PERSONA_AFTER=after.json] \
//    [SEWN_PERSONA_RUNS=5] [SEWN_PERSONA_VARIANTS=today,history,local,local+name] \
//    [SEWN_PERSONA_REPORT=report.md] HF_HOME=~/.rao/models/huggingface \
//    swift test --filter LocalPersonaLiveTests
//

import Foundation
import Logging
import XCTest
@testable import sewn_server

#if canImport(MLXLLM)
final class LocalPersonaLiveTests: XCTestCase {

    static let utterances = [
        "Hey, how's it going?",
        "Good morning.",
        "Thanks, that helps.",
        "Thanks, Mary.",
        "Mary, what time is it?",
        "What's your name?",
        "Who am I talking to?",
        "Do you know my name?",
        "What should I make for dinner tonight?",
        "I'm feeling a bit tired today.",
        "Tell me a joke.",
        "What's the capital of France?",
        "Can you remind me what we were talking about?",
        "Okay, good night.",
        "I just got back from a run.",
        "What do you think about working late?",
        "Hey Mary, are you there?",
        "My sister Mary is visiting next week.",
        "Who wrote Frankenstein?",
        "Say hi to me.",
    ]

    /// Two clean exchanges ahead of the utterance, for variants that send history.
    static let history: [Requests.Chat.Get.Message] = [
        .init(role: "user", content: "Hi."),
        .init(role: "assistant", content: "Hi! What's on your mind?"),
        .init(role: "user", content: "Not much, just checking in."),
        .init(role: "assistant", content: "Glad you did. I'm here whenever you want to talk."),
    ]

    struct Variant {
        let name: String
        let request: ChatCompletionRequest
        /// `localChatPersonaSection` (the on-device rendering) or today's section.
        let localSection: Bool
        let history: Bool
        let userName: String?
    }

    struct Tally {
        var replies = 0
        var vocative: [(utterance: String, reply: String)] = []
        var labels = 0
        var identityAsked = 0
        var identityNamed = 0
        var identityMissed: [(utterance: String, reply: String)] = []
        var sentences: [Int] = []
        var knowsName: [String] = []
    }

    func testTheOnDeviceModelKnowsWhoIsWho() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["SEWN_LOCAL_PERSONA_TESTS"] == "1", "set SEWN_LOCAL_PERSONA_TESTS=1 to run with a real model")
        let before = try Self.fixture(try XCTUnwrap(env["SEWN_PERSONA_BEFORE"], "SEWN_PERSONA_BEFORE is required"))
        let after = try env["SEWN_PERSONA_AFTER"].map(Self.fixture)
        let runs = env["SEWN_PERSONA_RUNS"].flatMap(Int.init) ?? 5
        let model = env["SEWN_LOCAL_PERSONA_MODEL"] ?? ModelConfig.defaultLocalModel
        let userName = env["SEWN_PERSONA_USER_NAME"] ?? "Ritesh"
        // SEWN_PERSONA_ONLY=6,7 runs just those utterances (1-based), for a quick look.
        let only = env["SEWN_PERSONA_ONLY"].map { Set($0.split(separator: ",").compactMap { Int($0) }) }
        let utterances = Self.utterances.enumerated()
            .filter { only?.contains($0.offset + 1) ?? true }.map(\.element)

        var variants = [
            Variant(name: "today", request: before, localSection: false, history: false, userName: nil),
            Variant(name: "history", request: before, localSection: false, history: true, userName: nil),
        ]
        if let after {
            variants.append(Variant(name: "local", request: after, localSection: true, history: true, userName: nil))
            variants.append(Variant(name: "local+name", request: after, localSection: true, history: true, userName: userName))
        }
        if let only = env["SEWN_PERSONA_VARIANTS"] {
            let wanted = Set(only.split(separator: ",").map(String.init))
            variants = variants.filter { wanted.contains($0.name) }
        }

        let store = FileManager.default.temporaryDirectory.appendingPathComponent("sewn-persona-\(UUID().uuidString)")
        let local = LocalInference(logger: Logger(label: "persona-eval"), storeDirectory: store, gpuPreflight: false)
        var report = "# On-device persona eval\n\nmodel \(model), \(runs) run(s) per utterance\n"

        var tallies: [String: Tally] = [:]
        for variant in variants {
            let name = variant.request.persona?.name ?? "Mary"
            let system = Self.system(for: variant)
            var tally = Tally()
            report += "\n## \(variant.name)\n\n```\n\(system.prefix(700))…\n```\n"
            for utterance in utterances {
                for seed in 1...runs {
                    let messages = (variant.history ? Self.history : []) + [.init(role: "user", content: utterance)]
                    let parameters = ChatGenerationParameters(
                        maxTokens: 160,
                        temperature: variant.request.temperature ?? 0.4,
                        topP: variant.request.topP ?? 0.9,
                        repetitionPenalty: variant.request.repetitionPenalty ?? 1.1,
                        repetitionContextSize: variant.request.repetitionContextSize ?? 20,
                        kvBits: nil, kvGroupSize: 64, quantizedKVStart: 0)
                    let reply = try await local.generate(
                        system: system, messages: messages, tools: nil, modelID: model,
                        sampling: LocalSampling(parameters, maxTokens: 160, seed: UInt64(seed)),
                        retrieved: [], turn: nil).text
                    tally.replies += 1
                    if !Self.vocatives(of: name, in: reply).isEmpty {
                        tally.vocative.append((utterance, reply))
                    }
                    if Self.hasSpeakerLabel(reply, names: [name, "User", "Assistant"]) { tally.labels += 1 }
                    if utterance == "What's your name?" || utterance == "Who am I talking to?" {
                        tally.identityAsked += 1
                        if reply.contains(name) { tally.identityNamed += 1 } else { tally.identityMissed.append((utterance, reply)) }
                    }
                    if utterance == "Do you know my name?", seed == 1 { tally.knowsName.append(reply) }
                    tally.sentences.append(Self.sentenceCount(reply))
                }
            }
            tallies[variant.name] = tally
            let line = Self.summary(variant.name, tally)
            print("[persona] \(line)")
            report += "\n\(line)\n\n\"Do you know my name?\" → \(tally.knowsName.first ?? "—")\n"
            for hit in tally.vocative {
                report += "\n- **\(hit.utterance)** → \(hit.reply.replacingOccurrences(of: "\n", with: " "))"
            }
            for miss in tally.identityMissed {
                report += "\n- identity miss: **\(miss.utterance)** → \(miss.reply.replacingOccurrences(of: "\n", with: " "))"
            }
            report += "\n"
        }

        let reportURL = env["SEWN_PERSONA_REPORT"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("persona-eval.md")
        try report.write(to: reportURL, atomically: true, encoding: .utf8)
        print("[persona] report → \(reportURL.path)")

        // The bar only applies to the on-device rendering; the others are the "before".
        for candidate in ["local", "local+name"] {
            guard let tally = tallies[candidate] else { continue }
            XCTAssertLessThanOrEqual(Double(tally.vocative.count) / Double(tally.replies), 0.02, "\(candidate): addresses the user by her own name")
            XCTAssertEqual(tally.labels, 0, "\(candidate): speaker labels")
            XCTAssertEqual(tally.identityNamed, tally.identityAsked, "\(candidate): forgets her own name")
        }
    }

    // MARK: - Prompt, exactly as handleChat builds it for an empty retrieval

    static func fixture(_ path: String) throws -> ChatCompletionRequest {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        return try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(contentsOf: url))
    }

    static func system(for variant: Variant) -> String {
        let persona = resolveChatPersona(inline: variant.request.persona, stored: nil)
        let memory = Sewn.memoryInstruction(contextEmpty: true, bonnieClient: false)
        let section = variant.localSection
            ? localChatPersonaSection(persona, userName: variant.userName, memoryInstruction: memory)
            : chatPersonaSection(persona, memoryInstruction: memory)
        return Sewn.systemPrompts(
            personaSection: section, instructions: Sewn.chatInstructions(variant.request.instructions),
            context: "").full
    }

    // MARK: - Scoring

    /// The name used to address someone: "Thanks, Mary!", "Hey Mary", "Mary, …".
    /// Self-introductions ("I'm Mary") and a third party ("Mary is visiting")
    /// are not address. Every hit is printed for a human to confirm.
    static func vocatives(of name: String, in reply: String) -> [String] {
        let n = NSRegularExpression.escapedPattern(for: name)
        let patterns = [
            #"(?:^|[.!?]\s+|\n)\s*"# + n + #"\s*[,!]"#,
            #",\s*"# + n + #"\s*[.!?,]"#,
            #"\b(?:Hi|Hey|Hello|Morning|Evening|Night|Thanks|Thank you|Welcome|Sure|Okay|Oh|Well|Yes|No|Dear|Sorry|Bye|Goodnight)\s+"# + n + #"\b"#,
        ]
        // "…talking to me, Mary." names herself: an apposition, not address.
        let selfNamed = try? NSRegularExpression(pattern: #"\b(?:me|I'm|I am|it's|It's|this is|This is)\s*,\s*"# + n + #"\b"#)
        let selfRanges = selfNamed?.matches(in: reply, range: NSRange(reply.startIndex..., in: reply)).map(\.range) ?? []
        return patterns.flatMap { pattern -> [String] in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            return regex.matches(in: reply, range: NSRange(reply.startIndex..., in: reply))
                .filter { match in !selfRanges.contains { NSIntersectionRange($0, match.range).length > 0 } }
                .compactMap { Range($0.range, in: reply).map { String(reply[$0]) } }
        }
    }

    static func hasSpeakerLabel(_ reply: String, names: [String]) -> Bool {
        names.contains { name in
            reply.range(of: #"(?:^|\n)\s*\#(NSRegularExpression.escapedPattern(for: name))\s*:"#, options: .regularExpression) != nil
        }
    }

    static func sentenceCount(_ reply: String) -> Int {
        max(1, reply.components(separatedBy: CharacterSet(charactersIn: ".!?")).filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count)
    }

    static func summary(_ name: String, _ tally: Tally) -> String {
        let sorted = tally.sentences.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let rate = tally.replies == 0 ? 0 : 100 * Double(tally.vocative.count) / Double(tally.replies)
        return "\(name): vocative \(tally.vocative.count)/\(tally.replies) (\(String(format: "%.1f", rate))%), labels \(tally.labels), identity \(tally.identityNamed)/\(tally.identityAsked), median sentences \(median)"
    }
}

/// The detector itself, without a model.
final class PersonaVocativeTests: XCTestCase {

    func testAddressIsCounted() {
        for reply in ["Thanks, Mary!", "Hey Mary, how are you?", "Good night, Mary.", "Mary, that's a great question.",
                      "Sounds lovely. Mary, what will you cook?"] {
            XCTAssertFalse(LocalPersonaLiveTests.vocatives(of: "Mary", in: reply).isEmpty, reply)
        }
    }

    func testSelfIntroductionAndThirdPartiesAreNot() {
        for reply in ["I'm Mary, nice to meet you.", "My name is Mary.", "How long is Mary staying?",
                      "You're talking to me, Mary. How's your day?",
                      "That's lovely — have fun with Mary!", "Hi! I'm doing well, thanks for asking."] {
            XCTAssertTrue(LocalPersonaLiveTests.vocatives(of: "Mary", in: reply).isEmpty, reply)
        }
    }

    func testSpeakerLabels() {
        XCTAssertTrue(LocalPersonaLiveTests.hasSpeakerLabel("Mary: Hello there.", names: ["Mary"]))
        XCTAssertFalse(LocalPersonaLiveTests.hasSpeakerLabel("Here's the thing: it's late.", names: ["Mary"]))
    }
}
#endif
