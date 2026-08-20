import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Settings")
                    .font(.seerSerif(22, weight: .light, italic: true))
                    .foregroundStyle(Color.seerInk)

                SeerCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            SectionLabel("Environment")
                            Spacer()
                            EnvironmentToggle()
                        }
                        Text("Local runs and supervises servers from your repo checkouts. Prod inspects a remote deployment read-only — Chat, Graph, Library, and Lab all follow this switch.")
                            .font(.seerSans(11))
                            .foregroundStyle(Color.seerInk.opacity(0.45))
                    }
                }

                SeerCard {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionLabel("Production endpoints")
                        settingsRow("Seer URL") {
                            TextField("https://api.seer.services", text: Binding(
                                get: { appState.servers.prodSeerURLString },
                                set: { appState.servers.prodSeerURLString = $0 }))
                                .textFieldStyle(.roundedBorder)
                                .font(.seerMono(11))
                        }
                        Text("Totems registered with the prod Seer are discovered automatically from /v1/totems. Add manual endpoints for nodes outside the fleet:")
                            .font(.seerSans(11))
                            .foregroundStyle(Color.seerInk.opacity(0.45))
                        ForEach(appState.servers.prodTotems) { totem in
                            prodTotemRow(totem)
                        }
                        Button {
                            appState.servers.addProdTotem()
                        } label: {
                            Label("Add Totem endpoint", systemImage: "plus")
                        }
                        .buttonStyle(.seerQuiet)
                    }
                }

                SeerCard {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionLabel("Repositories (local mode)")
                        settingsRow("Seer") {
                            TextField("", text: Binding(
                                get: { appState.servers.seerConfig.repoPath },
                                set: { appState.servers.seerConfig.repoPath = $0 }))
                                .textFieldStyle(.roundedBorder)
                                .font(.seerMono(11))
                            Button("Browse…") {
                                if let url = FilePicker.pickDirectory() {
                                    appState.servers.seerConfig.repoPath = url.path
                                }
                            }
                            .buttonStyle(.seerQuiet)
                        }
                        Text("Totem repo paths are configured per node on the Servers screen; new nodes default to the first node's path.")
                            .font(.seerSans(11))
                            .foregroundStyle(Color.seerInk.opacity(0.45))
                    }
                }

                SeerCard {
                    PersonalitiesSection()
                }

                SeerCard {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionLabel("Account")
                        AccountSection()
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        // Center the settings column: pinned-left it reads as a phantom empty
        // pane on wide windows (standard settings pages center their content).
        .frame(maxWidth: .infinity)
        .background(Color.seerBG)
    }

    /// Consistent label-column form row.
    private func settingsRow(@ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 8) { content() }
    }

    private func settingsRow(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.seerSans(12, weight: .medium))
                .foregroundStyle(Color.seerInk)
                .frame(width: 76, alignment: .leading)
                .fixedSize()
            content()
        }
    }

    private func prodTotemRow(_ totem: ProdTotemConfig) -> some View {
        HStack(spacing: 8) {
            TextField("name", text: bindingForProdTotem(totem, \.name))
                .textFieldStyle(.roundedBorder)
                .font(.seerSans(11))
                .frame(width: 120)
                .fixedSize()
            TextField("http://host:8081", text: bindingForProdTotem(totem, \.urlString))
                .textFieldStyle(.roundedBorder)
                .font(.seerMono(11))
            Button {
                appState.servers.removeProdTotem(totem)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.seerInk.opacity(0.3))
        }
    }

    private func bindingForProdTotem<T>(_ totem: ProdTotemConfig,
                                        _ keyPath: WritableKeyPath<ProdTotemConfig, T>) -> Binding<T> {
        Binding(
            get: {
                appState.servers.prodTotems.first { $0.id == totem.id }?[keyPath: keyPath]
                    ?? totem[keyPath: keyPath]
            },
            set: { newValue in
                guard let index = appState.servers.prodTotems.firstIndex(where: { $0.id == totem.id }) else { return }
                appState.servers.prodTotems[index][keyPath: keyPath] = newValue
            }
        )
    }
}

/// Sign-in state + controls, shared by Settings and the Chat sign-in sheet.
struct AccountSection: View {
    @EnvironmentObject private var appState: AppState
    @State private var email = ""
    @State private var password = ""
    @State private var status: String?
    @State private var signedInEmail: String? = UserDefaults.standard.string(forKey: "seer.client.email")

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .onChange(of: appState.sessionEpoch) {
            // Auto sign-in may complete after this view appeared.
            signedInEmail = UserDefaults.standard.string(forKey: "seer.client.email")
        }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if let signedInEmail {
                HStack {
                    StatusDot(color: .seerGreen)
                    Text(signedInEmail)
                        .font(.seerSans(12))
                    Spacer()
                    Button("Sign out") {
                        Task {
                            await appState.seerAPI.signOut()
                            self.signedInEmail = nil
                        }
                    }
                    .buttonStyle(.seerQuiet)
                }
            } else {
                TextField("email", text: $email)
                    .textFieldStyle(.roundedBorder)
                SecureField("password", text: $password)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Sign in") {
                        Task {
                            do {
                                try await appState.seerAPI.signIn(email: email, password: password)
                                signedInEmail = email
                                status = nil
                            } catch {
                                status = error.localizedDescription
                            }
                        }
                    }
                    .buttonStyle(.seer)
                    if let status {
                        Text(status)
                            .font(.seerSans(11))
                            .foregroundStyle(Color.seerError)
                    }
                }
            }
        }
    }
}
