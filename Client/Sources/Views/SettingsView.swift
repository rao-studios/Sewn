import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Settings")
                    .font(.sewnSerif(22, weight: .light, italic: true))
                    .foregroundStyle(Color.sewnInk)

                SewnCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            SectionLabel("Environment")
                            Spacer()
                            EnvironmentToggle()
                        }
                        Text("Local runs and supervises servers from your repo checkouts. Prod inspects a remote deployment read-only — Chat, Graph, Library, and Lab all follow this switch.")
                            .font(.sewnSans(11))
                            .foregroundStyle(Color.sewnInk.opacity(0.45))
                    }
                }

                SewnCard {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionLabel("Production endpoints")
                        settingsRow("Sewn URL") {
                            TextField("https://api.seer.services", text: Binding(
                                get: { appState.servers.prodSewnURLString },
                                set: { appState.servers.prodSewnURLString = $0 }))
                                .textFieldStyle(.roundedBorder)
                                .font(.sewnMono(11))
                        }
                        Text("Threads registered with the prod Sewn are discovered automatically from /v1/threads. Add manual endpoints for nodes outside the fleet:")
                            .font(.sewnSans(11))
                            .foregroundStyle(Color.sewnInk.opacity(0.45))
                        ForEach(appState.servers.prodThreads) { thread in
                            prodThreadRow(thread)
                        }
                        Button {
                            appState.servers.addProdThread()
                        } label: {
                            Label("Add Thread endpoint", systemImage: "plus")
                        }
                        .buttonStyle(.sewnQuiet)
                    }
                }

                SewnCard {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionLabel("Repositories (local mode)")
                        settingsRow("Sewn") {
                            TextField("", text: Binding(
                                get: { appState.servers.sewnConfig.repoPath },
                                set: { appState.servers.sewnConfig.repoPath = $0 }))
                                .textFieldStyle(.roundedBorder)
                                .font(.sewnMono(11))
                            Button("Browse…") {
                                if let url = FilePicker.pickDirectory() {
                                    appState.servers.sewnConfig.repoPath = url.path
                                }
                            }
                            .buttonStyle(.sewnQuiet)
                        }
                        Text("Thread repo paths are configured per node on the Servers screen; new nodes default to the first node's path.")
                            .font(.sewnSans(11))
                            .foregroundStyle(Color.sewnInk.opacity(0.45))
                    }
                }

                SewnCard {
                    PersonalitiesSection()
                }

                SewnCard {
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
        .background(Color.sewnBG)
    }

    /// Consistent label-column form row.
    private func settingsRow(@ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 8) { content() }
    }

    private func settingsRow(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.sewnSans(12, weight: .medium))
                .foregroundStyle(Color.sewnInk)
                .frame(width: 76, alignment: .leading)
                .fixedSize()
            content()
        }
    }

    private func prodThreadRow(_ thread: ProdThreadConfig) -> some View {
        HStack(spacing: 8) {
            TextField("name", text: bindingForProdThread(thread, \.name))
                .textFieldStyle(.roundedBorder)
                .font(.sewnSans(11))
                .frame(width: 120)
                .fixedSize()
            TextField("http://host:8081", text: bindingForProdThread(thread, \.urlString))
                .textFieldStyle(.roundedBorder)
                .font(.sewnMono(11))
            Button {
                appState.servers.removeProdThread(thread)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.sewnInk.opacity(0.3))
        }
    }

    private func bindingForProdThread<T>(_ thread: ProdThreadConfig,
                                        _ keyPath: WritableKeyPath<ProdThreadConfig, T>) -> Binding<T> {
        Binding(
            get: {
                appState.servers.prodThreads.first { $0.id == thread.id }?[keyPath: keyPath]
                    ?? thread[keyPath: keyPath]
            },
            set: { newValue in
                guard let index = appState.servers.prodThreads.firstIndex(where: { $0.id == thread.id }) else { return }
                appState.servers.prodThreads[index][keyPath: keyPath] = newValue
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
    @State private var signedInEmail: String? = UserDefaults.standard.string(forKey: "sewn.client.email")

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .onChange(of: appState.sessionEpoch) {
            // Auto sign-in may complete after this view appeared.
            signedInEmail = UserDefaults.standard.string(forKey: "sewn.client.email")
        }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if let signedInEmail {
                HStack {
                    StatusDot(color: .sewnGreen)
                    Text(signedInEmail)
                        .font(.sewnSans(12))
                    Spacer()
                    Button("Sign out") {
                        Task {
                            await appState.sewnAPI.signOut()
                            self.signedInEmail = nil
                        }
                    }
                    .buttonStyle(.sewnQuiet)
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
                                try await appState.sewnAPI.signIn(email: email, password: password)
                                signedInEmail = email
                                status = nil
                            } catch {
                                status = error.localizedDescription
                            }
                        }
                    }
                    .buttonStyle(.sewn)
                    if let status {
                        Text(status)
                            .font(.sewnSans(11))
                            .foregroundStyle(Color.sewnError)
                    }
                }
            }
        }
    }
}
