import SwiftUI

/// The ThinkingMachines research lab: manage the Python environment, build
/// datasets from Seer data, run SFT/DPO training on Tinker, browse runs and
/// checkpoints, test-chat models, and deploy checkpoints to Seer.
struct LabScreen: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var venv = VenvManager()
    @StateObject private var trainer = TrainController()

    enum Tab: String, CaseIterable, Identifiable {
        case environment = "Environment"
        case datasets = "Datasets"
        case train = "Train"
        case runs = "Runs"
        case testChat = "Test Chat"
        var id: String { rawValue }
    }

    @AppStorage("seer.client.labTab") private var tabRaw = Tab.environment.rawValue
    private var tab: Tab { Tab(rawValue: tabRaw) ?? .environment }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Lab") {
                Picker("", selection: $tabRaw) {
                    ForEach(Tab.allCases) { tab in
                        Text(tab.rawValue).tag(tab.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .tint(Color.seerGold)
                .frame(maxWidth: 420)
            } trailing: {
                venvBadge
            }

            Divider().overlay(Color.seerBorder)

            switch tab {
            case .environment: VenvPanel(venv: venv)
            case .datasets: LabDatasetsView(venv: venv)
            case .train: TrainView(venv: venv, trainer: trainer)
            case .runs: RunsView(venv: venv)
            case .testChat: TestChatView(venv: venv)
            }
        }
        .background(Color.seerBG)
        .task { await venv.detect() }
    }

    private var venvBadge: some View {
        HStack(spacing: 6) {
            switch venv.state {
            case .ready(let version):
                StatusDot(color: .seerGreen)
                Text("tinker \(version)").font(.seerMono(10))
            case .installing:
                StatusDot(color: .seerGold)
                Text("installing…").font(.seerMono(10))
            case .missing, .unknown:
                StatusDot(color: Color.seerInk.opacity(0.25))
                Text("no venv").font(.seerMono(10))
            case .broken(let reason):
                StatusDot(color: .seerError)
                Text(reason).font(.seerMono(10)).lineLimit(1)
            }
        }
        .foregroundStyle(Color.seerInk.opacity(0.6))
    }
}

// MARK: - Environment tab

struct VenvPanel: View {
    @ObservedObject var venv: VenvManager

    var body: some View {
        VStack(spacing: 14) {
            SeerCard {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Python environment")
                    Text(VenvManager.venvURL.path)
                        .font(.seerMono(10))
                        .foregroundStyle(Color.seerInk.opacity(0.5))
                    HStack {
                        switch venv.state {
                        case .ready(let version):
                            Label("tinker \(version) ready", systemImage: "checkmark.circle")
                                .foregroundStyle(Color.seerGreen)
                        case .missing:
                            Text("Virtualenv not found — install to enable training and run management.")
                                .font(.seerSans(12))
                        case .broken(let reason):
                            Text(reason).font(.seerSans(12)).foregroundStyle(Color.seerError)
                        case .installing:
                            ProgressView().controlSize(.small)
                            Text("Installing tinker + tinker-cookbook…").font(.seerSans(12))
                        case .unknown:
                            ProgressView().controlSize(.small)
                        }
                        Spacer()
                        Button(venv.state == .missing ? "Install" : "Reinstall") {
                            Task { await venv.install() }
                        }
                        .buttonStyle(.seer)
                        .disabled(venv.state == .installing)
                    }
                    if venv.apiKey.isEmpty {
                        Text("⚠︎ No TINKER_API_KEY found (Keychain or Seer/.env) — chat and helper calls will fail.")
                            .font(.seerSans(11))
                            .foregroundStyle(Color.seerError)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)

            LogView(title: "environment", buffer: venv.log)
        }
    }
}
