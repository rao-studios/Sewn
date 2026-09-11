import SwiftUI

/// Runs & checkpoints browser (via the tinker_helper JSON bridge), with
/// copy-URI and deploy-to-Sewn actions for sampler checkpoints.
struct RunsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var venv: VenvManager

    struct RunRow: Identifiable {
        let id: String
        let raw: [String: Any]
        var summary: String {
            let model = raw["base_model"] as? String ?? raw["model_name"] as? String ?? ""
            return model
        }
    }

    struct CheckpointRow: Identifiable {
        let id: String            // tinker path
        let raw: [String: Any]
        var isSampler: Bool { id.contains("sampler_weights") }
    }

    @State private var runs: [RunRow] = []
    @State private var checkpoints: [CheckpointRow] = []
    @State private var selectedRunId: String?
    @State private var status: String?
    @State private var deployedModel: String?
    @State private var personalities: [Personality] = []

    private var helper: TinkerHelper {
        TinkerHelper(pythonPath: VenvManager.pythonURL.path,
                     helperPath: venv.helperPath(),
                     apiKey: venv.apiKey)
    }

    var body: some View {
        HSplitView {
            runList
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
            checkpointList
                .frame(minWidth: 380)
        }
        .task { await refresh() }
        .onChange(of: appState.sessionEpoch) {
            Task {
                deployedModel = try? await appState.sewnAPI.adminModel().chatModel
                personalities = (try? await appState.sewnAPI.personalities()) ?? []
            }
        }
    }

    private var runList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel("Training runs")
                Spacer()
                if let status {
                    Text(status).font(.sewnSans(10.5)).foregroundStyle(Color.sewnInk.opacity(0.5))
                        .lineLimit(1)
                }
                Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.sewnQuiet)
            }
            .padding(14)

            List(runs, selection: $selectedRunId) { run in
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.id)
                        .font(.sewnMono(10.5))
                        .lineLimit(1).truncationMode(.middle)
                    if !run.summary.isEmpty {
                        Text(run.summary)
                            .font(.sewnSans(10.5))
                            .foregroundStyle(Color.sewnInk.opacity(0.5))
                    }
                }
                .tag(run.id)
            }
            .scrollContentBackground(.hidden)
        }
        .background(Color.sewnBG)
        .onChange(of: selectedRunId) { _, runId in
            if let runId { Task { await loadCheckpoints(runId: runId) } }
        }
    }

    private var checkpointList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel("Checkpoints")
                Spacer()
                if let deployedModel {
                    SewnPill(text: "serving: \(deployedModel.suffix(28))", tint: .sewnGreen)
                }
            }
            .padding(14)

            if checkpoints.isEmpty {
                EmptyHero(title: "No checkpoints",
                          subtitle: selectedRunId == nil
                              ? "Select a training run to list its checkpoints."
                              : "This run has no saved checkpoints yet.")
            } else {
                List(checkpoints) { checkpoint in
                    HStack(spacing: 8) {
                        Image(systemName: checkpoint.isSampler ? "waveform" : "internaldrive")
                            .foregroundStyle(checkpoint.isSampler ? Color.sewnGold : Color.sewnInk.opacity(0.4))
                        Text(checkpoint.id)
                            .font(.sewnMono(10))
                            .lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer()
                        Button("Copy URI") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(checkpoint.id, forType: .string)
                        }
                        .buttonStyle(.sewnQuiet)
                        if checkpoint.isSampler {
                            Button("Deploy to Sewn") {
                                Task { await deploy(checkpoint.id) }
                            }
                            .buttonStyle(.sewn)
                            if !personalities.isEmpty {
                                Menu("Deploy to…") {
                                    ForEach(personalities) { personality in
                                        Button(personality.name) {
                                            Task { await deploy(checkpoint.id, to: personality) }
                                        }
                                    }
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color.sewnBG)
    }

    // MARK: Data

    private func refresh() async {
        status = "loading…"
        do {
            let result = try await helper.runJSON(["list-runs"])
            runs = Self.extractRecords(result, idKeys: ["training_run_id", "run_id", "id"])
                .map { RunRow(id: $0.id, raw: $0.raw) }
            status = "\(runs.count) run(s)"
            deployedModel = try? await appState.sewnAPI.adminModel().chatModel
            personalities = (try? await appState.sewnAPI.personalities()) ?? []
        } catch {
            status = error.localizedDescription
            runs = []
        }
    }

    private func loadCheckpoints(runId: String) async {
        do {
            let result = try await helper.runJSON(["list-checkpoints", "--run", runId])
            checkpoints = Self.extractRecords(result, idKeys: ["tinker_path", "path", "id"])
                .map { CheckpointRow(id: $0.id, raw: $0.raw) }
        } catch {
            status = error.localizedDescription
            checkpoints = []
        }
    }

    private func deploy(_ tinkerPath: String) async {
        do {
            let response = try await appState.sewnAPI.setAdminModel(chatModel: tinkerPath)
            deployedModel = response.chatModel
            status = "deployed"
        } catch {
            status = "deploy failed: \(error.localizedDescription)"
        }
    }

    /// Pins the checkpoint as one personality's model override (admin PUT of
    /// the full persona list) — the global chat model stays untouched.
    private func deploy(_ tinkerPath: String, to personality: Personality) async {
        guard let index = personalities.firstIndex(where: { $0.id == personality.id }) else { return }
        var updated = personalities
        updated[index].modelOverride = tinkerPath
        do {
            personalities = try await appState.sewnAPI.updatePersonalities(updated)
            status = "deployed to \(personality.name)"
        } catch {
            status = "deploy failed: \(error.localizedDescription)"
        }
    }

    /// Digs id'd records out of loosely-shaped helper output (list, or an
    /// object wrapping a list under any key).
    static func extractRecords(_ value: Any?, idKeys: [String]) -> [(id: String, raw: [String: Any])] {
        var records: [[String: Any]] = []
        if let list = value as? [[String: Any]] {
            records = list
        } else if let object = value as? [String: Any] {
            for nested in object.values {
                if let list = nested as? [[String: Any]] { records.append(contentsOf: list) }
            }
            if records.isEmpty, idKeys.contains(where: { object[$0] != nil }) {
                records = [object]
            }
        }
        return records.compactMap { record in
            for key in idKeys {
                if let id = record[key] as? String { return (id, record) }
            }
            return nil
        }
    }
}
