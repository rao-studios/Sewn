import SwiftUI

/// Owns the currently running training process and its log.
@MainActor
final class TrainController: ObservableObject {
    @Published var isRunning = false
    @Published var lastExitStatus: Int32?
    let log = LogBuffer()
    private var process: ManagedProcess?

    func start(scriptURL: URL, venv: VenvManager) {
        guard !isRunning else { return }
        log.clear()
        lastExitStatus = nil
        let managed = ManagedProcess(log: log, ports: [])
        managed.onTermination = { [weak self] status in
            Task { @MainActor in
                self?.isRunning = false
                self?.lastExitStatus = status
            }
        }
        do {
            try managed.launch(
                arguments: [VenvManager.pythonURL.path, scriptURL.path],
                workingDirectory: scriptURL.deletingLastPathComponent(),
                extraEnvironment: ["TINKER_API_KEY": venv.apiKey]
            )
            process = managed
            isRunning = true
        } catch {
            log.append("launch failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        Task {
            await process?.stop()
            isRunning = false
        }
    }
}

/// Training tab: configure an SFT/DPO run, generate the script, launch it with
/// live logs. Scripts are plain Python in runs/<name>/train.py — editable
/// before launch for anything the form doesn't expose.
struct TrainView: View {
    @ObservedObject var venv: VenvManager
    @ObservedObject var trainer: TrainController

    @State private var runName = "run-\(Int(Date().timeIntervalSince1970) % 100000)"
    @State private var kind: TrainingTemplates.Config.Kind = .sft
    @State private var baseModel = "Qwen/Qwen3-8B"
    @State private var selectedDataset: URL?
    @State private var loraRank = 32
    @State private var learningRate = "1e-4"
    @State private var epochs = 1
    @State private var scriptURL: URL?
    @State private var status: String?

    private var datasets: [DatasetBuilder.BuiltDataset] { DatasetBuilder.listDatasets() }

    var body: some View {
        HSplitView {
            configPane
                .frame(minWidth: 340, idealWidth: 380, maxWidth: 440)
            LogView(title: "training", buffer: trainer.log)
                .frame(minWidth: 400)
        }
    }

    private var configPane: some View {
        ScrollView {
            VStack(spacing: 14) {
                SeerCard {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionLabel("Run configuration")

                        TextField("run name", text: $runName)
                            .textFieldStyle(.roundedBorder)

                        Picker("Recipe", selection: $kind) {
                            ForEach(TrainingTemplates.Config.Kind.allCases) { kind in
                                Text(kind.rawValue).tag(kind)
                            }
                        }
                        .pickerStyle(.segmented)
                        .tint(Color.seerGold)
                        Text(kind == .sft
                             ? "Supervised fine-tune from {messages: […]} rows."
                             : "Preference tuning from Sinatra-derived {prompt, chosen, rejected} pairs — Self-RLHF.")
                            .font(.seerSans(10.5))
                            .foregroundStyle(Color.seerInk.opacity(0.5))

                        TextField("base model", text: $baseModel)
                            .textFieldStyle(.roundedBorder)
                            .font(.seerMono(11))

                        Picker("Dataset", selection: $selectedDataset) {
                            Text("select…").tag(URL?.none)
                            ForEach(datasets.filter { kind == .dpo ? $0.kind == .dpo : $0.kind == .sft }) { dataset in
                                Text("\(dataset.name) (\(dataset.rows))").tag(URL?.some(dataset.url))
                            }
                        }

                        HStack(spacing: 16) {
                            Stepper("LoRA rank \(loraRank)", value: $loraRank, in: 4...128, step: 4)
                                .fixedSize()
                            Stepper("epochs \(epochs)", value: $epochs, in: 1...10)
                                .fixedSize()
                            Spacer(minLength: 0)
                        }
                        .font(.seerSans(11))
                        HStack(spacing: 8) {
                            Text("learning rate")
                                .font(.seerSans(11))
                                .fixedSize()
                            TextField("", text: $learningRate)
                                .textFieldStyle(.roundedBorder)
                                .font(.seerMono(11))
                                .frame(width: 80)
                                .fixedSize()
                            Spacer(minLength: 0)
                        }
                    }
                }

                SeerCard {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel("Launch")
                        HStack(spacing: 8) {
                            Button("Generate script") { generate() }
                                .buttonStyle(.seerQuiet)
                                .disabled(selectedDataset == nil)
                            if let scriptURL {
                                Button("Open") { NSWorkspace.shared.open(scriptURL) }
                                    .buttonStyle(.seerQuiet)
                            }
                            Spacer()
                            if trainer.isRunning {
                                Button("Stop") { trainer.stop() }.buttonStyle(.seerQuiet)
                            } else {
                                Button("Train") {
                                    if scriptURL == nil { generate() }
                                    if let scriptURL { trainer.start(scriptURL: scriptURL, venv: venv) }
                                }
                                .buttonStyle(.seer)
                                .disabled(selectedDataset == nil || venv.state == .missing)
                            }
                        }
                        if let status {
                            Text(status).font(.seerSans(11)).foregroundStyle(Color.seerInk.opacity(0.55))
                        }
                        if let exitStatus = trainer.lastExitStatus {
                            Text(exitStatus == 0 ? "✓ run finished — see Runs tab for checkpoints"
                                                 : "✗ exited with status \(exitStatus)")
                                .font(.seerSans(11))
                                .foregroundStyle(exitStatus == 0 ? Color.seerGreen : Color.seerError)
                        }
                        Text("The generated train.py is editable — tweak recipe fields the form doesn't expose, then Train.")
                            .font(.seerSans(10.5))
                            .foregroundStyle(Color.seerInk.opacity(0.45))
                    }
                }
            }
            .padding(20)
        }
    }

    private func generate() {
        guard let dataset = selectedDataset else { return }
        var config = TrainingTemplates.Config(
            runName: runName.isEmpty ? "run" : runName,
            datasetPath: dataset.path
        )
        config.baseModel = baseModel
        config.loraRank = loraRank
        config.learningRate = Double(learningRate) ?? 1e-4
        config.epochs = epochs
        config.kind = kind
        do {
            scriptURL = try TrainingTemplates.write(config)
            status = "script → \(scriptURL!.path)"
        } catch {
            status = error.localizedDescription
        }
    }
}
