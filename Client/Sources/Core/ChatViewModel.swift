import Foundation
import SwiftUI

/// Latest chat transcript snapshot, shared so the Lab's personality-SFT
/// builder can train on the current conversation without owning the view model.
@MainActor
enum ChatTranscriptStore {
    static var latest: [ChatViewModel.Message] = []
}

@MainActor
final class ChatViewModel: ObservableObject {

    struct Message: Identifiable {
        let id = UUID()
        let role: Role
        var text: String
        var references: [ChatReference] = []
        var contribution: ChatContribution?
        /// Personality id echoed by the server for this response.
        var personality: String?
        /// When set, CitationText emphasizes only this document's exact spans.
        var emphasizedDocumentId: String?

        enum Role { case user, assistant }
    }

    @Published var messages: [Message] = []
    @Published var draft = ""
    @Published var isStreaming = false
    @Published var isSignedIn = false
    @Published var totems: [TotemNodeEntry] = []
    @Published var personalTotemId: String?
    @Published var activeModel: String?
    @Published var personalities: [Personality] = []
    @Published var selectedPersonality: String {
        didSet { UserDefaults.standard.set(selectedPersonality, forKey: Self.personalityKey) }
    }
    @Published var streamTick = 0
    @Published var error: String?

    private static let personalityKey = "seer.client.personality"

    private var api: SeerAPI?
    private var streamTask: Task<Void, Never>?

    init() {
        selectedPersonality = UserDefaults.standard.string(forKey: Self.personalityKey) ?? "seer"
    }

    func attach(api: SeerAPI) {
        self.api = api
    }

    func refreshState() async {
        guard let api else { return }
        isSignedIn = await api.isSignedIn
        totems = (try? await api.totems())?.nodes.filter { $0.isActive } ?? []
        activeModel = try? await api.adminModel().chatModel
        if isSignedIn {
            personalities = (try? await api.personalities()) ?? personalities
            if !personalities.isEmpty, !personalities.contains(where: { $0.id == selectedPersonality }) {
                selectedPersonality = personalities[0].id
            }
        }
    }

    func send() {
        if isStreaming {
            streamTask?.cancel()
            isStreaming = false
            return
        }
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, let api else { return }
        draft = ""
        error = nil

        messages.append(Message(role: .user, text: prompt))
        messages.append(Message(role: .assistant, text: ""))
        isStreaming = true

        // History: send prior turns + the new prompt (roles as the API expects).
        let history: [[String: String]] = messages.dropLast().map {
            ["role": $0.role == .user ? "user" : "assistant", "content": $0.text]
        }

        let personalTotem = personalTotemId
        let personality = selectedPersonality.isEmpty ? nil : selectedPersonality
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await api.chatStream(
                    messages: history,
                    personality: personality,
                    personalTotemId: personalTotem
                )
                for try await event in stream {
                    if Task.isCancelled { break }
                    switch event {
                    case .references(let references):
                        self.updateLast { $0.references = references }
                    case .delta(let text):
                        self.updateLast { $0.text += text }
                        self.streamTick += 1
                    case .contribution(let contribution):
                        self.updateLast { $0.contribution = contribution }
                    case .personality(let id):
                        self.updateLast { $0.personality = id }
                    case .done:
                        break
                    }
                }
            } catch {
                self.error = error.localizedDescription
                self.updateLast { message in
                    if message.text.isEmpty {
                        message.text = "⚠︎ \(error.localizedDescription)"
                    }
                }
            }
            self.isStreaming = false
            self.streamTick += 1
            ChatTranscriptStore.latest = self.messages
        }
    }

    /// Toggles per-document span emphasis on a message: tapping a source chip
    /// highlights only that document's exact spans; tapping again clears it.
    func toggleEmphasis(messageId: UUID, documentId: String) {
        guard let index = messages.firstIndex(where: { $0.id == messageId }) else { return }
        messages[index].emphasizedDocumentId =
            messages[index].emphasizedDocumentId == documentId ? nil : documentId
    }

    /// True when any owner in the message's contribution carries exact spans
    /// for `documentId` — the chip only toggles emphasis when there is
    /// something to emphasize.
    func hasDocumentSpans(_ message: Message, documentId: String) -> Bool {
        message.contribution?.owners?.contains {
            !($0.documentSpans?[documentId]?.isEmpty ?? true)
        } ?? false
    }

    private func updateLast(_ mutate: (inout Message) -> Void) {
        guard !messages.isEmpty else { return }
        mutate(&messages[messages.count - 1])
    }
}
