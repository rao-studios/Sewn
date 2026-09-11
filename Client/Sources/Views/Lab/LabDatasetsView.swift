import SwiftUI
import UniformTypeIdentifiers

/// Datasets tab: build SFT/DPO JSONL from Sewn data or import existing JSONL.
struct LabDatasetsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var venv: VenvManager

    @State private var datasets: [DatasetBuilder.BuiltDataset] = []
    @State private var status: String?
    @State private var dpoMargin = 0.15
    @State private var personalities: [Personality] = []
    @State private var sftPersonalityId = ""

    var body: some View {
        HSplitView {
            buildersPane
                .frame(minWidth: 340, idealWidth: 400, maxWidth: 480)
            datasetList
                .frame(minWidth: 320)
        }
        .onAppear { datasets = DatasetBuilder.listDatasets() }
        .task {
            await loadPersonalities()
        }
        .onChange(of: appState.sessionEpoch) {
            Task { await loadPersonalities() }
        }
    }

    private var buildersPane: some View {
        ScrollView {
            VStack(spacing: 14) {
                SewnCard {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel("DPO from Sinatra (Self-RLHF)")
                        Text("Exports your Sinatra state from Sewn and pairs highest-vs-lowest sentiment-weight responses per query into {prompt, chosen, rejected} rows. Unpaired positives spill into an SFT file.")
                            .font(.sewnSans(11))
                            .foregroundStyle(Color.sewnInk.opacity(0.55))
                        HStack(spacing: 12) {
                            Text("weight margin ≥ \(String(format: "%.2f", dpoMargin))")
                                .font(.sewnMono(10.5))
                                .foregroundStyle(Color.sewnInk.opacity(0.65))
                                .frame(width: 150, alignment: .leading)
                                .fixedSize()
                            Slider(value: $dpoMargin, in: 0.05...0.6)
                                .controlSize(.small)
                            Button("Build") { buildDPO() }
                                .buttonStyle(.sewn)
                        }
                        Text("Requires sign-in (Settings) and a running Sewn.")
                            .font(.sewnSans(10.5))
                            .foregroundStyle(Color.sewnInk.opacity(0.4))
                    }
                }

                SewnCard {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel("Personality SFT (voice + citations)")
                        Text("Builds SFT rows from the current chat transcript, trained as the chosen personality: its voice fragment + citation protocol as the system message, and [[n]] source markers re-inserted into the assistant targets from their exact document spans.")
                            .font(.sewnSans(11))
                            .foregroundStyle(Color.sewnInk.opacity(0.55))
                        HStack(spacing: 12) {
                            Picker("", selection: $sftPersonalityId) {
                                ForEach(personalities) { personality in
                                    Text(personality.name).tag(personality.id)
                                }
                            }
                            .frame(width: 140)
                            .fixedSize()
                            Spacer()
                            Button("Build from chat") { buildPersonalitySFT() }
                                .buttonStyle(.sewn)
                                .disabled(personalities.isEmpty)
                        }
                        Text("Chat first (marked responses give the strongest rows), then build.")
                            .font(.sewnSans(10.5))
                            .foregroundStyle(Color.sewnInk.opacity(0.4))
                    }
                }

                SewnCard {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel("Import JSONL")
                        Text("Bring your own rows — {messages: […]} for SFT or {prompt, chosen, rejected} for DPO (name the file with 'dpo' to tag it).")
                            .font(.sewnSans(11))
                            .foregroundStyle(Color.sewnInk.opacity(0.55))
                        Button("Choose file…") { importJSONL() }
                            .buttonStyle(.sewnQuiet)
                    }
                }

                if let status {
                    Text(status)
                        .font(.sewnSans(11))
                        .foregroundStyle(Color.sewnInk.opacity(0.6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
            }
            .padding(20)
        }
    }

    private var datasetList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel("Datasets — \(VenvManager.datasetsURL.path)")
                Spacer()
                Button { datasets = DatasetBuilder.listDatasets() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.sewnQuiet)
            }
            .padding(14)

            if datasets.isEmpty {
                EmptyHero(title: "No datasets yet",
                          subtitle: "Build DPO pairs from Sinatra or import a JSONL file.")
            } else {
                List(datasets) { dataset in
                    HStack(spacing: 8) {
                        SewnPill(text: dataset.kind.rawValue.uppercased(),
                                 tint: dataset.kind == .dpo ? .sewnGold : .sewnGreen)
                        Text(dataset.name).font(.sewnMono(11))
                        Spacer()
                        Text("\(dataset.rows) rows")
                            .font(.sewnSans(10.5))
                            .foregroundStyle(Color.sewnInk.opacity(0.5))
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([dataset.url])
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.sewnInk.opacity(0.4))
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color.sewnBG)
    }

    private func buildDPO() {
        status = "exporting Sinatra state…"
        Task {
            do {
                let data = try await appState.sewnAPI.frankExport()
                let (dpo, spillover) = try DatasetBuilder.buildDPO(
                    fromFrankExport: data,
                    name: "sinatra-\(Int(Date().timeIntervalSince1970) % 100000)",
                    margin: dpoMargin
                )
                var message = "built \(dpo.name): \(dpo.rows) pair(s)"
                if let spillover { message += " + \(spillover.rows) SFT spillover" }
                if dpo.rows == 0 {
                    message += " — not enough contrasting interactions yet; keep chatting to grow the signal"
                }
                status = message
                datasets = DatasetBuilder.listDatasets()
            } catch {
                status = error.localizedDescription
            }
        }
    }

    private func loadPersonalities() async {
        personalities = (try? await appState.sewnAPI.personalities()) ?? []
        if sftPersonalityId.isEmpty { sftPersonalityId = personalities.first?.id ?? "" }
    }

    private func buildPersonalitySFT() {
        guard let personality = personalities.first(where: { $0.id == sftPersonalityId }) else { return }
        let transcript = ChatTranscriptStore.latest
        guard transcript.contains(where: { $0.role == .assistant && !$0.text.isEmpty }) else {
            status = "no chat transcript yet — have a conversation on the Chat screen first"
            return
        }
        do {
            let built = try DatasetBuilder.buildPersonalitySFT(from: transcript,
                                                               personality: personality)
            let marked = transcript.filter {
                $0.contribution?.owners?.contains { !($0.documentSpans?.isEmpty ?? true) } ?? false
            }.count
            status = "built \(built.name): \(built.rows) row(s), \(marked) with exact source markers"
            datasets = DatasetBuilder.listDatasets()
        } catch {
            status = error.localizedDescription
        }
    }

    private func importJSONL() {
        guard let url = FilePicker.pickFiles().first else { return }
        do {
            let imported = try DatasetBuilder.importJSONL(
                from: url,
                name: url.deletingPathExtension().lastPathComponent
            )
            status = "imported \(imported.name): \(imported.rows) rows"
            datasets = DatasetBuilder.listDatasets()
        } catch {
            status = error.localizedDescription
        }
    }
}

/// Test-chat tab: A/B compare two Tinker models (base vs checkpoint) directly
/// against the Anthropic-compatible API — sampling works mid-training.
struct TestChatView: View {
    @ObservedObject var venv: VenvManager

    @State private var modelA = "thinkingmachines/Inkling-Small"
    @State private var modelB = ""
    @State private var prompt = ""
    @State private var outputA = ""
    @State private var outputB = ""
    @State private var isStreaming = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("model A (base or tinker://…)", text: $modelA)
                    .textFieldStyle(.roundedBorder).font(.sewnMono(11))
                TextField("model B (optional — A/B compare)", text: $modelB)
                    .textFieldStyle(.roundedBorder).font(.sewnMono(11))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)

            HSplitView {
                outputPane(title: modelA, text: outputA)
                if !modelB.isEmpty {
                    outputPane(title: modelB, text: outputB)
                }
            }

            if let error {
                Text(error)
                    .font(.sewnSans(11))
                    .foregroundStyle(Color.sewnError)
                    .padding(.horizontal, 24)
            }

            HStack(spacing: 10) {
                TextField("prompt…", text: $prompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.sewnSerif(14, weight: .regular, italic: true))
                    .lineLimit(1...4)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.white.opacity(0.8))
                            .overlay(RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Color.sewnBorder, lineWidth: 1))
                    )
                    .onSubmit { send() }
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.sewnGold))
                }
                .buttonStyle(.plain)
                .disabled(isStreaming || prompt.isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
    }

    private func outputPane(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(String(title.suffix(44)))
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
            ScrollView {
                Text(text.isEmpty ? "…" : text)
                    .font(.sewnSans(13))
                    .foregroundStyle(Color.sewnInk)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
            }
            .background(Color.sewnFill)
        }
    }

    private func send() {
        let message = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        error = nil
        outputA = ""; outputB = ""
        isStreaming = true
        let api = TinkerAPI(apiKey: venv.apiKey)
        let messages = [["role": "user", "content": message]]
        let modelBValue = modelB

        Task {
            async let first: Void = streamInto(\TestChatView.outputA, api: api,
                                               model: modelA, messages: messages)
            if !modelBValue.isEmpty {
                async let second: Void = streamInto(\TestChatView.outputB, api: api,
                                                    model: modelBValue, messages: messages)
                _ = await (first, second)
            } else {
                _ = await first
            }
            isStreaming = false
        }
    }

    private func streamInto(_ keyPath: WritableKeyPath<TestChatView, String>,
                            api: TinkerAPI, model: String,
                            messages: [[String: String]]) async {
        do {
            for try await delta in await api.stream(model: model, messages: messages) {
                if keyPath == \TestChatView.outputA { outputA += delta } else { outputB += delta }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
