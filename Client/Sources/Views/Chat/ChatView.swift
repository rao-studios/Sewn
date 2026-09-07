import SwiftUI

/// Sewn chat with cited sources: streams the response, then applies the
/// span-annotated contribution as per-owner highlights. Lives as the center
/// pane of the Workspace, which owns the view model.
struct ChatPane: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var viewModel: ChatViewModel
    /// Fired on any source-chip tap so the workspace can highlight the
    /// document's entities in the Graph pane.
    var onReferenceTap: ((ChatReference) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.sewnBorder)

            if !viewModel.isSignedIn {
                EmptyHero(title: "Sign in to chat",
                          subtitle: "Chat requires a Sewn account — sign in below or from Settings.")
                signInInline
            } else if viewModel.messages.isEmpty {
                EmptyHero(title: "Ask Sewn",
                          subtitle: "Responses cite their sources — spans are highlighted per contributing owner, with references you can inspect.")
            } else {
                transcript
            }

            composer
        }
        .background(Color.sewnBG)
        .task {
            viewModel.attach(api: appState.sewnAPI)
            await viewModel.refreshState()
        }
        .onChange(of: appState.servers.readyEpoch) {
            Task { await viewModel.refreshState() }
        }
        .onChange(of: appState.sessionEpoch) {
            Task { await viewModel.refreshState() }
        }
    }

    private var header: some View {
        PaneHeader {
            HStack(spacing: 8) {
                SectionLabel("Chat")
                if let model = viewModel.activeModel {
                    SewnPill(text: model)
                        .frame(maxWidth: 150)
                }
                Spacer(minLength: 8)
                if !viewModel.personalities.isEmpty {
                    Picker("", selection: $viewModel.selectedPersonality) {
                        ForEach(viewModel.personalities) { personality in
                            Text(personality.name).tag(personality.id)
                        }
                    }
                    .frame(minWidth: 70, maxWidth: 110)
                    .layoutPriority(1)
                    .help(viewModel.personalities.first {
                        $0.id == viewModel.selectedPersonality
                    }?.tagline ?? "")
                }
                SectionLabel("Thread")
                Picker("", selection: $viewModel.personalThreadId) {
                    Text("auto").tag(String?.none)
                    ForEach(viewModel.threads) { node in
                        Text(String(node.threadId.prefix(8)).lowercased())
                            .tag(String?.some(node.threadId))
                    }
                }
                .frame(minWidth: 70, maxWidth: 110)
                .layoutPriority(1)
                Button {
                    Task { await viewModel.refreshState() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.sewnIcon)
                .help("Refresh threads, personalities, and session state")
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(viewModel.messages) { message in
                        MessageRow(
                            message: message,
                            onReferenceTap: { reference in
                                // Chip tap: emphasize that source file's exact spans
                                // when the marker path produced them, and let the
                                // workspace highlight the document in the graph.
                                if viewModel.hasDocumentSpans(message, documentId: reference.id) {
                                    viewModel.toggleEmphasis(messageId: message.id,
                                                             documentId: reference.id)
                                }
                                onReferenceTap?(reference)
                            }
                        )
                        .id(message.id)
                    }
                }
                .padding(24)
            }
            .onChange(of: viewModel.streamTick) {
                if let last = viewModel.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var signInInline: some View {
        SewnCard {
            AccountSection()
        }
        .frame(maxWidth: 420)
        .padding(.bottom, 24)
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Ask something grounded in your documents…", text: $viewModel.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.sewnSerif(15, weight: .regular, italic: true))
                .foregroundStyle(Color.sewnLabel)
                .lineLimit(1...4)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.white.opacity(0.8))
                        .overlay(RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(Color.sewnBorder, lineWidth: 1))
                )
                .onSubmit { viewModel.send() }

            Button {
                viewModel.send()
            } label: {
                Image(systemName: viewModel.isStreaming ? "stop.fill" : "arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.sewnGold))
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.isSignedIn)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }
}

// MARK: - Message row

private struct MessageRow: View {
    let message: ChatViewModel.Message
    let onReferenceTap: (ChatReference) -> Void

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
            if message.role == .user {
                Text(message.text)
                    .font(.sewnSerif(15, weight: .regular, italic: true))
                    .foregroundStyle(Color.sewnInk)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.sewnGold.opacity(0.10))
                    )
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                SewnCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        if let personality = message.personality {
                            SewnPill(text: personality)
                        }
                        CitationText(text: message.text,
                                     contribution: message.contribution,
                                     emphasizedDocumentId: message.emphasizedDocumentId)
                        if !message.references.isEmpty {
                            ReferenceStrip(references: message.references,
                                           contribution: message.contribution,
                                           emphasizedDocumentId: message.emphasizedDocumentId,
                                           onTap: onReferenceTap)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Reference strip

private struct ReferenceStrip: View {
    let references: [ChatReference]
    let contribution: ChatContribution?
    var emphasizedDocumentId: String? = nil
    let onTap: (ChatReference) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                SectionLabel("Sources")
                ForEach(references) { reference in
                    let isEmphasized = reference.id == emphasizedDocumentId
                    Button {
                        onTap(reference)
                    } label: {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(CitationPalette.color(for: reference.ownerId ?? "",
                                                            in: contribution))
                                .frame(width: 6, height: 6)
                            Text(String(reference.id.prefix(10)))
                                .font(.sewnMono(9.5))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(isEmphasized
                                ? Color.sewnGold.opacity(0.25)
                                : Color.sewnFill)
                        )
                        .overlay(
                            Capsule().strokeBorder(
                                isEmphasized ? Color.sewnGold : .clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
