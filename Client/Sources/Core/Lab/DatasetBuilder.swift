import Foundation

/// Builds training JSONL files under App Support `datasets/`:
///  - **SFT** rows `{messages: [{role, content}...]}` from chat transcripts or
///    imported JSONL.
///  - **DPO** rows `{prompt: [...], chosen: str, rejected: str}` from Sewn's
///    Sinatra export: interactions grouped by query, best-vs-worst by
///    sentiment-derived weight when the gap clears a margin. Unpaired rows
///    spill over into an SFT file so no signal is wasted.
enum DatasetBuilder {

    struct BuiltDataset: Identifiable {
        let id = UUID()
        let name: String
        let url: URL
        let rows: Int
        let kind: Kind

        enum Kind: String { case sft, dpo }
    }

    static func listDatasets() -> [BuiltDataset] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: VenvManager.datasetsURL, includingPropertiesForKeys: nil)) ?? []
        return contents.filter { $0.pathExtension == "jsonl" }.compactMap { url in
            let rows = (try? String(contentsOf: url, encoding: .utf8))?
                .split(separator: "\n").count ?? 0
            let kind: BuiltDataset.Kind = url.lastPathComponent.contains("dpo") ? .dpo : .sft
            return BuiltDataset(name: url.lastPathComponent, url: url, rows: rows, kind: kind)
        }
        .sorted { $0.name < $1.name }
    }

    // MARK: - SFT from chat transcript

    /// One SFT row per assistant turn, with the preceding conversation as context.
    static func buildSFT(from messages: [ChatViewModel.Message], name: String) throws -> BuiltDataset {
        var rows: [[String: Any]] = []
        var context: [[String: String]] = []
        for message in messages {
            let role = message.role == .user ? "user" : "assistant"
            context.append(["role": role, "content": message.text])
            if message.role == .assistant, !message.text.isEmpty {
                rows.append(["messages": context])
            }
        }
        return try write(rows: rows, name: sanitized(name), kind: .sft)
    }

    // MARK: - Personality SFT (voice + marker discipline)

    /// The citation protocol the Sewn server injects for marked chats —
    /// mirrored here so SFT rows train against the same instruction.
    static let citationProtocol = """
    When a sentence draws on a bracketed source [n], append that source's marker \
    immediately after the sentence, formatted exactly as [[n]] (several are allowed \
    in a row, e.g. [[1]][[3]]). The markers are machine-read and stripped before \
    the user sees your reply — never mention them, never explain them, and never \
    use a number that does not appear in the context.
    """

    /// One SFT row per assistant turn, trained as the personality: the system
    /// message is the persona's voice fragment + citation protocol, and the
    /// assistant target has `[[n]]` markers re-inserted from `document_spans`
    /// (numbered by the message's reference order). Teaches voice and marker
    /// discipline together; turns without exact spans still supervise voice.
    static func buildPersonalitySFT(
        from messages: [ChatViewModel.Message],
        personality: Personality
    ) throws -> BuiltDataset {
        let system = [personality.systemFragment, citationProtocol]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        var rows: [[String: Any]] = []
        var context: [[String: String]] = [["role": "system", "content": system]]
        for message in messages {
            if message.role == .user {
                context.append(["role": "user", "content": message.text])
            } else if !message.text.isEmpty {
                let marked = markedResponse(for: message)
                rows.append(["messages": context + [["role": "assistant", "content": marked]]])
                // History carries the visible (unmarked) text, matching what the
                // model sees as prior turns at inference time.
                context.append(["role": "assistant", "content": message.text])
            }
        }
        return try write(rows: rows, name: sanitized(personality.id) + "-sft", kind: .sft)
    }

    /// Re-inserts `[[n]]` markers into a visible response: one marker at each
    /// exact document span's upper bound, `n` = 1-based position of that
    /// document in the message's reference list.
    static func markedResponse(for message: ChatViewModel.Message) -> String {
        let referenceIndex = Dictionary(
            message.references.enumerated().map { ($1.id, $0 + 1) },
            uniquingKeysWith: { first, _ in first }
        )
        var insertions: [(offset: Int, marker: String)] = []
        var seen = Set<String>()
        for owner in message.contribution?.owners ?? [] {
            for (documentId, spans) in owner.documentSpans ?? [:] {
                guard let index = referenceIndex[documentId] else { continue }
                for span in spans {
                    let key = "\(documentId):\(span.upper)"
                    guard seen.insert(key).inserted else { continue }
                    insertions.append((span.upper, "[[\(index)]]"))
                }
            }
        }
        guard !insertions.isEmpty else { return message.text }

        var characters = Array(message.text)
        // Insert back-to-front so earlier offsets stay valid; equal offsets
        // sort by marker for deterministic run order.
        for insertion in insertions.sorted(by: { ($0.offset, $0.marker) > ($1.offset, $1.marker) }) {
            let position = min(max(insertion.offset, 0), characters.count)
            characters.insert(contentsOf: insertion.marker, at: position)
        }
        return String(characters)
    }

    /// Imports pre-built JSONL rows verbatim (validated as JSON objects).
    static func importJSONL(from source: URL, name: String) throws -> BuiltDataset {
        let content = try String(contentsOf: source, encoding: .utf8)
        var rows: [[String: Any]] = []
        for line in content.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            rows.append(object)
        }
        return try write(rows: rows, name: sanitized(name), kind: .sft)
    }

    // MARK: - DPO from Sinatra export

    /// Sinatra's export carries the interaction history with per-interaction
    /// sentiment weights. Pairs are formed within same-query groups:
    /// highest-weight response = `chosen`, lowest = `rejected`, gap ≥ `margin`.
    static func buildDPO(fromFrankExport data: Data, name: String,
                         margin: Double = 0.15) throws -> (dpo: BuiltDataset, spillover: BuiltDataset?) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "DatasetBuilder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Frank export is not a JSON object"])
        }

        // The export shape nests per-owner state; walk it defensively for
        // interaction records that carry (query, response, weight).
        var interactions: [(query: String, response: String, weight: Double)] = []
        func walk(_ node: Any) {
            if let dictionary = node as? [String: Any] {
                if let query = (dictionary["query"] ?? dictionary["user_message"]) as? String,
                   let response = (dictionary["response"] ?? dictionary["assistant_message"]) as? String,
                   let weight = (dictionary["weight"] ?? dictionary["sentiment_weight"]) as? Double {
                    interactions.append((query, response, weight))
                }
                dictionary.values.forEach(walk)
            } else if let array = node as? [Any] {
                array.forEach(walk)
            }
        }
        walk(root)

        var byQuery: [String: [(response: String, weight: Double)]] = [:]
        for interaction in interactions {
            byQuery[interaction.query, default: []].append((interaction.response, interaction.weight))
        }

        var dpoRows: [[String: Any]] = []
        var spilloverRows: [[String: Any]] = []
        for (query, candidates) in byQuery {
            let sorted = candidates.sorted { $0.weight > $1.weight }
            if sorted.count >= 2,
               let best = sorted.first, let worst = sorted.last,
               best.weight - worst.weight >= margin {
                dpoRows.append([
                    "prompt": [["role": "user", "content": query]],
                    "chosen": best.response,
                    "rejected": worst.response,
                ])
            } else if let best = sorted.first, best.weight > 0 {
                spilloverRows.append(["messages": [
                    ["role": "user", "content": query],
                    ["role": "assistant", "content": best.response],
                ]])
            }
        }

        let dpo = try write(rows: dpoRows, name: sanitized(name) + "-dpo", kind: .dpo)
        var spillover: BuiltDataset?
        if !spilloverRows.isEmpty {
            spillover = try write(rows: spilloverRows, name: sanitized(name) + "-sft-spillover", kind: .sft)
        }
        return (dpo, spillover)
    }

    // MARK: - Write

    private static func write(rows: [[String: Any]], name: String,
                              kind: BuiltDataset.Kind) throws -> BuiltDataset {
        try FileManager.default.createDirectory(at: VenvManager.datasetsURL,
                                                withIntermediateDirectories: true)
        let url = VenvManager.datasetsURL.appendingPathComponent("\(name).jsonl")
        var lines: [String] = []
        for row in rows {
            let data = try JSONSerialization.data(withJSONObject: row)
            if let line = String(data: data, encoding: .utf8) { lines.append(line) }
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return BuiltDataset(name: url.lastPathComponent, url: url, rows: lines.count, kind: kind)
    }

    private static func sanitized(_ name: String) -> String {
        let cleaned = name.lowercased()
            .replacingOccurrences(of: "[^a-z0-9-_]", with: "-", options: .regularExpression)
        return cleaned.isEmpty ? "dataset" : cleaned
    }
}
