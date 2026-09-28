//
//  Sewn+Recap.swift
//  sewn-server
//
//  WHAT: The running recap — a few lines per compacted stretch of chat,
//        newest first, that ride the system prompt after the client drops
//        its history on auto-memory, so the chat never feels like it began
//        again.
//  IN:   autoMemorize (a new stretch's summary), handleChat and the realtime
//        opener (reading it), a request's `recap_reset` (forgetting it).
//  OUT:  `recapSection`, the prompt block; one ledger document per owner and
//        app in Thread's memory group.
//  PIN:  A turn never waits on Thread for this. The ledger is read by id
//        (ThreadLibrary.Documents, no embedding) into an in-memory cache;
//        a cold turn gives that read `recapHydrationBudgetNs` and goes
//        without if it is late. Writes happen in auto-memory's background
//        task. The ledger is filtered out of chat retrieval by its id prefix.
//

import Conduit
import Foundation
import RaoStack

extension Sewn {
    struct RecapEntry: Equatable, Sendable {
        let at: Date
        let text: String
    }

    /// One conversation's recap: an owner as one app sees them.
    struct RecapKey: Hashable, Sendable {
        let ownerId: String
        let app: RaoApp?

        init(ownerId: String, app: RaoApp?) {
            self.ownerId = ownerId.lowercased()
            self.app = app
        }

        init(_ request: SewnRequest) {
            self.init(ownerId: request.ownerId, app: request.callerApp)
        }
    }

    /// Every ledger id starts with this. Retrieval drops ids with it.
    static let recapDocumentPrefix = "chat-recap-"
    /// A single marker tag. A non-empty tag list also spares Thread its LLM
    /// entity pass; a plain word would become an entity any message matches.
    static let recapTag = "sewnrecap"
    /// Entries the ledger keeps; the prompt budget usually shows fewer.
    static let recapLedgerLimit = 12
    /// How long a cold turn waits, after its search, for the ledger read.
    static let recapHydrationBudgetNs: UInt64 = 200_000_000

    /// The prompt budget for the recap, in estimated tokens.
    static var recapMaxTokens: Int {
        ProcessInfo.processInfo.environment["SEWN_RECAP_MAX_TOKENS"]
            .flatMap(Int.init) ?? 600
    }

    static func recapDocumentId(ownerId: String, app: RaoApp?) -> String {
        let owner = ownerId.lowercased()
        guard let app else { return recapDocumentPrefix + owner }
        return recapDocumentPrefix + app.rawValue + "-" + owner
    }

    static func recapDocumentId(_ key: RecapKey) -> String {
        recapDocumentId(ownerId: key.ownerId, app: key.app)
    }
}

// MARK: - The prompt block

extension Sewn {
    static let recapHeader = "--- EARLIER IN THIS CONVERSATION ---"

    /// The recap as a system-prompt block: whole entries, newest first, until
    /// `maxTokens` is spent. The newest always shows, cut short if it alone is
    /// over. Nil when there is nothing to show.
    static func recapSection(
        _ entries: [RecapEntry],
        now: Date = Date(),
        maxTokens: Int = recapMaxTokens
    ) -> String? {
        let ordered = entries.sorted { $0.at > $1.at }
        guard !ordered.isEmpty, maxTokens > 0 else { return nil }
        let budgetBytes = maxTokens * Gita.StreamBilling.bytesPerToken

        var lines: [String] = []
        var spent = 0
        for entry in ordered {
            let line = "- (\(recapAge(of: entry.at, now: now))) \(entry.text)"
            let cost = line.utf8.count
            if lines.isEmpty && cost > budgetBytes {
                lines.append(truncated(line, toBytes: budgetBytes))
                break
            }
            guard spent + cost <= budgetBytes else { break }
            lines.append(line)
            spent += cost
        }

        return """
        \(recapHeader)
        Notes on what you and the user already discussed before the recent messages, most recent first. Treat them as shared history: build on them and don't re-ask what is settled, but never announce, list or recite them.
        \(lines.joined(separator: "\n"))
        ---
        """
    }

    /// How long ago, in the words a person would use.
    static func recapAge(of date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let minutes = Int(seconds / 60)
        let hours = minutes / 60
        let days = hours / 24
        switch true {
        case minutes < 1: return "just now"
        case minutes == 1: return "a minute ago"
        case minutes < 60: return "\(minutes) minutes ago"
        case hours == 1: return "an hour ago"
        case hours < 24: return "\(hours) hours ago"
        case days == 1: return "yesterday"
        default: return "\(days) days ago"
        }
    }

    private static func truncated(_ text: String, toBytes limit: Int) -> String {
        var out = ""
        var bytes = 0
        for character in text {
            let size = String(character).utf8.count
            guard bytes + size <= max(0, limit - 3) else { break }
            out.append(character)
            bytes += size
        }
        return out + "…"
    }
}

// MARK: - The ledger document

extension Sewn {
    /// One text per entry, newest first: `[<ISO-8601>] <recap>`.
    static func encodeLedger(_ entries: [RecapEntry]) -> [String] {
        let formatter = ISO8601DateFormatter()
        return entries.sorted { $0.at > $1.at }.map { entry in
            let flat = entry.text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return "[\(formatter.string(from: entry.at))] \(flat)"
        }
    }

    /// The entries back from the texts Thread returns. A line that doesn't
    /// open with a date continues the entry before it, so a text Thread split
    /// in two still reads as one entry. Newest first.
    static func parseLedger(_ texts: [String]) -> [RecapEntry] {
        let formatter = ISO8601DateFormatter()
        var entries: [(at: Date, text: String)] = []
        for line in texts.joined(separator: "\n").components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("["),
               let close = trimmed.firstIndex(of: "]"),
               let at = formatter.date(from: String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])) {
                let text = trimmed[trimmed.index(after: close)...].trimmingCharacters(in: .whitespaces)
                entries.append((at, text))
            } else if !entries.isEmpty {
                entries[entries.count - 1].text += " " + trimmed
            }
        }
        return entries
            .filter { !$0.text.isEmpty }
            .map { RecapEntry(at: $0.at, text: $0.text) }
            .sorted { $0.at > $1.at }
    }

    /// Two lists as one: newest first, an entry both hold kept once.
    static func mergeRecaps(_ a: [RecapEntry], _ b: [RecapEntry]) -> [RecapEntry] {
        var seen = Set<String>()
        return (a + b)
            .sorted { $0.at > $1.at }
            .filter { seen.insert("\(Int($0.at.timeIntervalSince1970))|\($0.text)").inserted }
    }
}

// MARK: - The cache

extension Sewn {
    /// Recaps by conversation. A key is hydrated once Thread's copy has been
    /// read (or there is no Thread to read); entries written before that are
    /// merged with Thread's when it arrives. `epoch` moves on a forget, so a
    /// read or a recap that started before it lands nowhere.
    final class RecapStore: @unchecked Sendable {
        private struct Slot {
            var entries: [RecapEntry] = []
            var hydrated = false
            var hydrating = false
            var epoch = 0
        }

        private let slots = LockedValue<[RecapKey: Slot]>([:])

        /// The entries, or nil while Thread's copy hasn't been read.
        func entries(for key: RecapKey) -> [RecapEntry]? {
            slots.withLock { slot in
                guard let s = slot[key], s.hydrated else { return nil }
                return s.entries
            }
        }

        /// The entries as they stand, read or not.
        func cached(for key: RecapKey) -> [RecapEntry] {
            slots.withLock { $0[key]?.entries ?? [] }
        }

        func epoch(for key: RecapKey) -> Int {
            slots.withLock { $0[key]?.epoch ?? 0 }
        }

        /// True for the one caller that should read Thread now.
        func beginHydration(_ key: RecapKey) -> (begin: Bool, epoch: Int) {
            slots.withLock { slot in
                var s = slot[key] ?? Slot()
                defer { slot[key] = s }
                guard !s.hydrated, !s.hydrating else { return (false, s.epoch) }
                s.hydrating = true
                return (true, s.epoch)
            }
        }

        /// Thread's copy, merged in. `fetched` nil means the read failed:
        /// the key stays unread and the next turn tries again.
        func finishHydration(_ key: RecapKey, epoch: Int, fetched: [RecapEntry]?) {
            slots.withLock { slot in
                var s = slot[key] ?? Slot()
                defer { slot[key] = s }
                guard s.epoch == epoch else { return }
                s.hydrating = false
                guard let fetched, !s.hydrated else { return }
                s.entries = Array(Sewn.mergeRecaps(s.entries, fetched).prefix(Sewn.recapLedgerLimit))
                s.hydrated = true
            }
        }

        /// A new entry at the head. False when a forget came first.
        @discardableResult
        func prepend(_ entry: RecapEntry, to key: RecapKey, ifEpoch epoch: Int) -> Bool {
            slots.withLock { slot in
                var s = slot[key] ?? Slot()
                guard s.epoch == epoch else { return false }
                s.entries = Array(Sewn.mergeRecaps([entry], s.entries).prefix(Sewn.recapLedgerLimit))
                slot[key] = s
                return true
            }
        }

        /// Forget: empty, known empty, and anything in flight ignored.
        func clear(_ key: RecapKey) {
            slots.withLock { slot in
                let epoch = (slot[key]?.epoch ?? 0) + 1
                slot[key] = Slot(entries: [], hydrated: true, hydrating: false, epoch: epoch)
            }
        }
    }
}

// MARK: - Reading, writing, forgetting

extension Sewn {
    /// Starts the ledger read for a cold key and returns the task, or nil
    /// when the cache already has it (or another turn is reading it).
    nonisolated func startRecapHydration(_ request: SewnRequest) -> Task<Void, Never>? {
        let key = RecapKey(request)
        guard recapStore.entries(for: key) == nil else { return nil }
        let (begin, epoch) = recapStore.beginHydration(key)
        guard begin else { return nil }
        return Task { [weak self] in
            guard let self else { return }
            let fetched = await self.fetchRecapLedger(key, request: request)
            self.recapStore.finishHydration(key, epoch: epoch, fetched: fetched)
        }
    }

    /// The recap block for this turn. A cold key's read gets
    /// `recapHydrationBudgetNs`; late, the turn goes without and the read
    /// still fills the cache for the next one.
    nonisolated func recapSection(
        for request: SewnRequest,
        awaiting hydration: Task<Void, Never>?
    ) async -> String? {
        let key = RecapKey(request)
        if let hydration, recapStore.entries(for: key) == nil {
            await Self.waitBriefly(for: hydration, ns: Self.recapHydrationBudgetNs)
        }
        return recapStore.entries(for: key).flatMap { Self.recapSection($0) }
    }

    /// The block from the cache alone — for the realtime opener, which waits on nothing.
    nonisolated func cachedRecapSection(for request: SewnRequest) -> String? {
        recapStore.entries(for: RecapKey(request)).flatMap { Self.recapSection($0) }
    }

    /// Thread's copy of the ledger. Nil when it couldn't be read; empty when
    /// there is none yet, or no Thread at all (the recap then lives here).
    nonisolated func fetchRecapLedger(_ key: RecapKey, request: SewnRequest) async -> [RecapEntry]? {
        guard _threadQueryClient != nil else { return [] }
        let id = Self.recapDocumentId(key)
        guard let documents = await fanoutDocuments(
            ownerId: key.ownerId,
            documentIds: [id],
            threadIds: request.personalThreadId.map { [$0] },
            app: key.app
        ) else { return nil }
        guard let document = documents.first(where: { $0.id == id }) else { return [] }
        return Self.parseLedger(document.texts)
    }

    /// Condenses a stretch's auto-memory summary into a recap entry, puts it
    /// at the head of the conversation's ledger and writes the ledger back.
    /// Runs inside auto-memory's background task.
    func recordRecap(
        summary: String,
        request: SewnRequest,
        modelProvider: ModelProvider,
        provider: LLMProvider
    ) async {
        let key = RecapKey(request)
        let epoch = recapStore.epoch(for: key)
        let at = Date()

        let text = await condenseRecap(summary, modelProvider: modelProvider, provider: provider)
        guard !text.isEmpty else { return }
        guard recapStore.prepend(RecapEntry(at: at, text: text), to: key, ifEpoch: epoch) else {
            logger.debug("Recap", "Forgotten while condensing — dropped", service: .sewn, request: request)
            return
        }

        // The ledger is rewritten whole, so Thread's copy must be in hand
        // first; if it can't be read, the entry waits here for the next one.
        if recapStore.entries(for: key) == nil {
            let fetched = await fetchRecapLedger(key, request: request)
            recapStore.finishHydration(key, epoch: epoch, fetched: fetched)
        }
        guard let entries = recapStore.entries(for: key) else {
            logger.warning("Recap: Thread's ledger unreadable — kept in memory for owner \(request.ownerId)", service: .sewn, request: request)
            return
        }
        guard _threadQueryClient != nil else { return }

        let recapRequest = SewnRequest(
            ownerId: request.ownerId,
            group: Sewn.Group(
                id: "memory-\(request.ownerId)",
                label: Self.autoMemoryGroupLabel,
                ownerId: request.ownerId,
                documents: []
            ),
            threadIds: request.personalThreadId.map { [$0] },
            callerApp: request.callerApp
        )
        let item = BatchPutItem(
            id: Self.recapDocumentId(key),
            texts: Self.encodeLedger(entries),
            tags: [Self.recapTag],
            tagsEmbedding: nil, mediaType: .text, update: nil,
            name: "Chat recap", metadata: nil)
        enqueuePut([item], request: recapRequest)
        logger.info("Recap", "📝 Recap recorded (\(entries.count) entr\(entries.count == 1 ? "y" : "ies")) for owner: \(request.ownerId)", service: .sewn, request: request)
    }

    /// Forgets the conversation's recap: here at once, so the turn that asked
    /// is built without it, and in Thread behind it.
    nonisolated func clearRecap(_ request: SewnRequest) {
        let key = RecapKey(request)
        recapStore.clear(key)
        logger.info("Recap", "📝 Recap forgotten for owner: \(request.ownerId)", service: .sewn, request: request)
        Task { [weak self] in
            await self?.fanoutRemove(
                documentIds: [Self.recapDocumentId(key)],
                ownerId: key.ownerId,
                targetThreadIds: nil,
                app: key.app)
        }
    }

    /// A few sentences from the summary; the summary's own prose, cut short,
    /// when the model gives nothing back.
    private func condenseRecap(
        _ summary: String,
        modelProvider: ModelProvider,
        provider: LLMProvider
    ) async -> String {
        let systemPrompt = """
        You condense a conversation summary into a short recap for the assistant who is continuing that same conversation. \
        Write 2 to 4 plain sentences, under 80 words. Call the user "the user" and the assistant "you" \
        (e.g. "The user asked about X; you suggested Y."). Keep names, numbers and decisions, and say what was left open. \
        No title, no markdown, no preamble.
        """
        let condensed = try? await StandaloneGeneration.runLLM(
            summary,
            systemPrompt: systemPrompt,
            maxTokens: 160,
            provider: provider,
            modelProvider: modelProvider,
            logger: baseLogger
        )
        let text = (condensed ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty, text != "Unknown" { return text }
        return Self.recapFallback(from: summary)
    }

    /// The summary without its bold title, flattened and cut to 400 characters.
    static func recapFallback(from summary: String) -> String {
        let lines = summary.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let prose = (lines.first?.hasPrefix("**") == true ? Array(lines.dropFirst()) : lines)
            .joined(separator: " ")
            .replacingOccurrences(of: "**", with: "")
        guard prose.count > 400 else { return prose }
        return String(prose.prefix(399)) + "…"
    }

    /// Waits for `task` or `ns`, whichever comes first. The task is never
    /// cancelled — a late read still lands in the cache. Not a task group:
    /// a group waits for every child, and `task.value` ignores cancellation.
    static func waitBriefly(for task: Task<Void, Never>, ns: UInt64) async {
        let gate = LockedValue<CheckedContinuation<Void, Never>?>(nil)
        let open: @Sendable () -> Void = {
            gate.withLock { $0?.resume(); $0 = nil }
        }
        await withCheckedContinuation { continuation in
            gate.withLock { $0 = continuation }
            Task { await task.value; open() }
            Task { try? await Task.sleep(nanoseconds: ns); open() }
        }
    }
}
