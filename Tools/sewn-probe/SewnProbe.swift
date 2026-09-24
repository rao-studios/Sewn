//
//  SewnProbe.swift
//  sewn-probe
//
//  WHAT: Talk to a running Sewn from the terminal — stream a chat turn (and a follow-up
//        that labels it), compare decoding with and without SinatraMLX, and read back
//        what the injection did to the logits.
//
//    swift run sewn-probe chat --provider local "What do my notes say about X?" --then "Tell me more"
//    swift run sewn-probe chat --trace full --seed 1 "…"
//    swift run sewn-probe compare --seed 1 "…"
//    swift run sewn-probe providers | warm [--model id] | trace <id> | analysis
//

import ArgumentParser
import Foundation

@main
struct SewnProbe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sewn-probe",
        abstract: "Probe Sewn's chat wire and SinatraMLX's on-device injection.",
        subcommands: [Chat.self, Compare.self, Providers.self, Warm.self, TraceCommand.self, Analysis.self])
}

// MARK: - Connection

struct Connection: ParsableArguments {
    @Option(help: "Sewn base URL (default $SEWN_BASE, else http://127.0.0.1:8080, or :47080 with --app).")
    var base: String?

    @Option(help: "Sign-in email (default $SEWN_DEV_EMAIL).")
    var email: String?

    @Option(help: "Sign-in password (default $SEWN_DEV_PASSWORD).")
    var password: String?

    @Option(help: "Bearer token instead of signing in (default $SEWN_TOKEN).")
    var token: String?

    @Option(help: "Stack secret for X-Ambient-Secret (a RAO_HOME or single-app Sewn).")
    var secret: String?

    @Option(help: "Read the stack secret from $RAO_HOME/secrets/<app> (e.g. ambient).")
    var app: String?

    struct Session {
        var http: SewnHTTP
        var ownerId: String?
    }

    func connect() async throws -> Session {
        let env = ProcessInfo.processInfo.environment
        var secret = self.secret
        if secret == nil, let app {
            let home = env["RAO_HOME"].map { ($0 as NSString).expandingTildeInPath } ?? (NSHomeDirectory() + "/.rao")
            let file = URL(fileURLWithPath: home).appendingPathComponent("secrets").appendingPathComponent(app)
            secret = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let defaultBase = app != nil ? "http://127.0.0.1:47080" : "http://127.0.0.1:8080"
        guard let url = URL(string: base ?? env["SEWN_BASE"] ?? defaultBase) else {
            throw ValidationError("--base is not a URL")
        }
        var http = SewnHTTP(base: url, token: token ?? env["SEWN_TOKEN"], secret: secret)
        var owner: String?
        if http.token == nil {
            guard let email = email ?? env["SEWN_DEV_EMAIL"], let password = password ?? env["SEWN_DEV_PASSWORD"] else {
                throw ValidationError("Pass --token, or --email/--password (or SEWN_DEV_EMAIL/SEWN_DEV_PASSWORD).")
            }
            let signIn = try await http.signIn(email: email, password: password)
            http.token = signIn.accessToken
            owner = signIn.userId.lowercased()
        }
        return Session(http: http, ownerId: owner)
    }
}

// MARK: - Chat

struct TurnOptions: ParsableArguments {
    @Option(help: "Backend: local, mistral, tinker.")
    var provider = "local"

    @Option(help: "Model id (on-device: a Hugging Face id, e.g. mlx-community/Mistral-Small-3.2-24B-Instruct-2506-4bit).")
    var model: String?

    @Option(help: "Retrieval group, id:label (repeatable). None = aggregate over the owner's documents.")
    var group: [String] = []

    @Option(help: "Owner id for the sewn object (default: the signed-in user).")
    var ownerId: String?

    @Option(help: "Max tokens.")
    var maxTokens = 400

    @Option(help: "Temperature.")
    var temperature: Float?

    @Option(help: "SinatraMLX mode: off, lexical, dense.")
    var mode: String?

    @Option(help: "SinatraMLX trace: automatic, off, summary, full.")
    var trace: String?

    @Option(help: "Sampler seed (fixed seeds make decodes comparable).")
    var seed: UInt64?

    func body(messages: [[String: String]], owner: String?, sinatra: [String: Any]?, stream: Bool = true) throws -> Data {
        var sewn: [String: Any] = [
            "owner_id": ownerId ?? owner ?? "probe",
            "scope": "personal",
            "aggregate": group.isEmpty,
            "request_id": UUID().uuidString,
        ]
        if !group.isEmpty {
            sewn["groups"] = group.map { item -> [String: String] in
                let parts = item.split(separator: ":", maxSplits: 1).map(String.init)
                return ["id": parts[0], "label": parts.count > 1 ? parts[1] : parts[0], "owner_id": ownerId ?? owner ?? ""]
            }
        }
        var body: [String: Any] = [
            "messages": messages, "stream": stream, "max_tokens": maxTokens, "provider": provider, "sewn": sewn,
        ]
        if let model { body["model"] = model }
        if let temperature { body["temperature"] = temperature }
        if let sinatra, !sinatra.isEmpty { body["sinatra"] = sinatra }
        return try JSONSerialization.data(withJSONObject: body)
    }

    var sinatraOptions: [String: Any] {
        var options: [String: Any] = [:]
        if let mode { options["mode"] = mode }
        if let trace { options["trace"] = trace }
        if let seed { options["seed"] = seed }
        return options
    }
}

struct TurnResult {
    var text: String
    var sinatra: SinatraDiagnostics?
    var ttft: TimeInterval?
    var total: TimeInterval
}

func runTurn(_ session: Connection.Session, body: Data, echo: Bool) async throws -> TurnResult {
    let start = Date()
    var ttft: TimeInterval?
    var text = ""
    var sinatra: SinatraDiagnostics?
    let decoder = JSONDecoder()
    for try await payload in try await session.http.events("v1/chat/completions", body: body) {
        if let failure = try? decoder.decode(StreamFailure.self, from: Data(payload.utf8)) {
            print("\n[stream error] \(failure.error.message ?? "generation failed")")
            continue
        }
        guard let chunk = try? decoder.decode(Chunk.self, from: Data(payload.utf8)) else { continue }
        if let s = chunk.sinatra { sinatra = s }
        for choice in chunk.choices ?? [] {
            if let content = choice.delta?.content, !content.isEmpty {
                if ttft == nil { ttft = Date().timeIntervalSince(start) }
                text += content
                if echo {
                    print(content, terminator: "")
                    fflush(stdout)
                }
            }
        }
    }
    if echo { print() }
    return TurnResult(text: text, sinatra: sinatra, ttft: ttft, total: Date().timeIntervalSince(start))
}

struct Chat: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stream a chat turn; --then sends a follow-up that labels it through SinatraMLX's feedback loop.")

    @OptionGroup var connection: Connection
    @OptionGroup var turn: TurnOptions

    @Argument(help: "The user's message.")
    var message: String

    @Option(help: "A follow-up message sent after the reply (it labels the first turn).")
    var then: String?

    @Option(help: "Seconds to wait before the follow-up (reply latency is part of the label).")
    var pause: Double = 3

    @Option(help: "Trace steps to print when a trace was requested.")
    var steps = 40

    func run() async throws {
        let session = try await connection.connect()
        var messages = [["role": "user", "content": message]]
        Render.rule("you")
        print(message)
        Render.rule("\(turn.provider)\(turn.model.map { " · \($0)" } ?? "")")
        let first = try await runTurn(session, body: turn.body(messages: messages, owner: session.ownerId, sinatra: turn.sinatraOptions), echo: true)
        try await report(first, session: session)

        guard let then else { return }
        if pause > 0 { try await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000)) }
        messages.append(["role": "assistant", "content": first.text])
        messages.append(["role": "user", "content": then])
        Render.rule("you")
        print(then)
        Render.rule("\(turn.provider)\(turn.model.map { " · \($0)" } ?? "")")
        let second = try await runTurn(session, body: turn.body(messages: messages, owner: session.ownerId, sinatra: turn.sinatraOptions), echo: true)
        try await report(second, session: session)
    }

    func report(_ result: TurnResult, session: Connection.Session) async throws {
        print(String(format: "\n(ttft %@, total %.2f s)", result.ttft.map { String(format: "%.2f s", $0) } ?? "–", result.total))
        guard let sinatra = result.sinatra else {
            if turn.provider == "local" { print("(no sinatra object: the turn did not reach SinatraMLX)") }
            return
        }
        Render.sinatra(sinatra)
        if let brief = sinatra.trace, (turn.trace == "summary" || turn.trace == "full") {
            let data = try await session.http.data("v1/providers/local/sinatra/traces/\(brief.traceId)")
            let trace = try JSONDecoder().decode(Trace.self, from: data)
            Render.trace(trace, steps: steps)
        }
    }
}

// MARK: - Compare

struct Compare: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Send one message twice — SinatraMLX off, then on — with the same seed, and compare the decodes.")

    @OptionGroup var connection: Connection
    @OptionGroup var turn: TurnOptions

    @Argument(help: "The user's message.")
    var message: String

    func run() async throws {
        let session = try await connection.connect()
        let seed = turn.seed ?? 1
        let messages = [["role": "user", "content": message]]
        let injectedMode = (turn.mode == nil || turn.mode == "off") ? "lexical" : turn.mode!

        Render.rule("baseline (sinatra off, seed \(seed))")
        let baseline = try await runTurn(session, body: turn.body(
            messages: messages, owner: session.ownerId,
            sinatra: ["mode": "off", "trace": "summary", "seed": seed, "record": false]), echo: true)
        Render.rule("with sinatra (\(injectedMode), seed \(seed))")
        let injected = try await runTurn(session, body: turn.body(
            messages: messages, owner: session.ownerId,
            sinatra: ["mode": injectedMode, "trace": "summary", "seed": seed, "record": false]), echo: true)

        Render.rule("comparison")
        let prefix = zip(baseline.text, injected.text).prefix { $0 == $1 }.count
        print(baseline.text == injected.text
            ? "identical output (\(baseline.text.count) characters) — nothing to steer yet, or the bias never won a step"
            : "outputs share their first \(prefix) of \(max(baseline.text.count, injected.text.count)) characters")
        if let s = injected.sinatra {
            Render.sinatra(s)
        }
        var curves: [(String, Trace)] = []
        for (label, result) in [("baseline", baseline), ("injected", injected)] {
            if let id = result.sinatra?.trace?.traceId,
                let data = try? await session.http.data("v1/providers/local/sinatra/traces/\(id)"),
                let trace = try? JSONDecoder().decode(Trace.self, from: data)
            {
                curves.append((label, trace))
            }
        }
        if curves.count == 2 {
            let (b, i) = (curves[0].1, curves[1].1)
            print("mean entropy per step: baseline \(Render.f(b.summary.meanEntropyPost)) vs injected \(Render.f(i.summary.meanEntropyPost)) (ΔH \(Render.signed(i.summary.meanEntropyPost - b.summary.meanEntropyPost)))")
            print("injected decode: divergence \(Render.f(i.summary.divergenceRate * 100, 1))% of steps, first at \(i.summary.firstDivergenceStep.map(String.init) ?? "–"), gain Σ \(Render.signed(i.summary.totalGain)) nats")
            print("  step  baseline token          H      | injected token          H")
            for k in 0..<min(40, max(b.steps.count, i.steps.count)) {
                let left = k < b.steps.count ? "\(Render.pad(Render.token(b.steps[k].sampledText), 22)) \(Render.f(b.steps[k].entropyPost, 2))" : Render.pad("", 27)
                let right = k < i.steps.count ? "\(Render.pad(Render.token(i.steps[k].sampledText), 22)) \(Render.f(i.steps[k].entropyPost, 2))" : ""
                let marker = k < b.steps.count && k < i.steps.count && b.steps[k].sampled != i.steps[k].sampled ? "≠" : " "
                print("  \(Render.pad(String(k), 4)) \(left) \(marker)| \(right)")
            }
        }
    }
}

// MARK: - Providers, warm, trace, analysis

struct Providers: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show GET /v1/providers, with SinatraMLX's status on the local row.")
    @OptionGroup var connection: Connection

    func run() async throws {
        let session = try await connection.connect()
        let payload = try JSONDecoder().decode(ProvidersPayload.self, from: await session.http.data("v1/providers"))
        for row in payload.providers {
            let mark = row.id == payload.default ? "*" : " "
            print("\(mark) \(Render.pad(row.id, 8)) \(Render.pad(row.state, 9)) \(row.available ? "available" : "unavailable")  \(row.model)\(row.progress.map { String(format: "  %.0f%%", $0 * 100) } ?? "")")
            if let reason = row.reason { print("    \(reason)") }
            if let s = row.sinatra {
                print("    sinatra: \(s.observations ?? 0) turns observed, \(s.labelled ?? 0) labelled, reliability \(Render.f(Float(s.reliability ?? 0), 2)), trained \(s.trainedAt ?? "never"), last |bias| \(Render.f(Float(s.lastBiasMagnitude ?? 0), 2))")
                if let store = s.store { print("    store: \(store)") }
            }
        }
    }
}

struct Warm: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Load the on-device model now (POST /v1/providers/local/warm).")
    @OptionGroup var connection: Connection

    @Option(help: "The model to warm (default: Sewn's configured on-device model).")
    var model: String?

    func run() async throws {
        let session = try await connection.connect()
        let body = try model.map { try JSONSerialization.data(withJSONObject: ["model": $0]) }
        print(String(data: try await session.http.data("v1/providers/local/warm", method: "POST", body: body), encoding: .utf8) ?? "")
    }
}

struct TraceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "trace", abstract: "Render one of your SinatraMLX traces.")
    @OptionGroup var connection: Connection

    @Argument(help: "Trace id (the `trace_id` from a turn's sinatra object).")
    var id: String

    @Option(help: "Steps to print.")
    var steps = 60

    func run() async throws {
        let session = try await connection.connect()
        let trace = try JSONDecoder().decode(Trace.self, from: await session.http.data("v1/providers/local/sinatra/traces/\(id)"))
        Render.trace(trace, steps: steps)
    }
}

struct Analysis: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Entropy against personalization for your account.")
    @OptionGroup var connection: Connection

    func run() async throws {
        let session = try await connection.connect()
        let data = try await session.http.data("v1/providers/local/sinatra/analysis")
        let object = try JSONSerialization.jsonObject(with: data)
        print(String(data: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8) ?? "")
    }
}
