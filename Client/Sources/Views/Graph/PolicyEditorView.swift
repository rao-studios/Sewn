import SwiftUI

/// Rename sheet for a selected entity.
struct RenameEntitySheet: View {
    @ObservedObject var viewModel: GraphViewModel
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename entity")
                .font(.sewnSerif(18, weight: .light, italic: true))
            TextField("new name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .onSubmit { commit() }
            HStack {
                Button("Cancel") { viewModel.renamingEntityId = nil }
                    .buttonStyle(.sewnQuiet)
                Button("Rename") { commit() }
                    .buttonStyle(.sewn)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .onAppear {
            name = viewModel.nodes.first { $0.id == viewModel.renamingEntityId }?.entity.name ?? ""
        }
    }

    private func commit() {
        guard let entityId = viewModel.renamingEntityId else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        viewModel.rename(entityId: entityId, to: trimmed)
        viewModel.renamingEntityId = nil
    }
}

/// Extraction-policy editor: ontology, prompt template, predicate aliases,
/// caps, and the auto-edge rules that shape in-flight entity/edge creation.
struct PolicyEditorView: View {
    @ObservedObject var viewModel: GraphViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var policy: ExtractionPolicyModel?
    @State private var status: String?
    @State private var newKindName = ""
    @State private var newKindDescription = ""
    @State private var newAliasFrom = ""
    @State private var newAliasTo = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Extraction Policy")
                    .font(.sewnSerif(20, weight: .light, italic: true))
                Spacer()
                if let status {
                    Text(status)
                        .font(.sewnSans(11))
                        .foregroundStyle(Color.sewnInk.opacity(0.5))
                }
                Button("Close") { dismiss() }
                    .buttonStyle(.sewnQuiet)
                Button("Save") { save() }
                    .buttonStyle(.sewn)
                    .disabled(policy == nil)
            }
            .padding(20)

            Divider().overlay(Color.sewnBorder)

            if policy != nil {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ontologySection
                        promptSection
                        aliasSection
                        autoEdgeSection
                    }
                    .padding(20)
                }
            } else {
                EmptyHero(title: "Loading policy…",
                          subtitle: status ?? "Fetching the extraction policy from the selected Thread node.")
            }
        }
        .background(Color.sewnBG)
        .task { await load() }
    }

    // MARK: Sections

    private var ontologySection: some View {
        SewnCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Ontology — entity kinds")
                ForEach(policy?.kinds ?? []) { kind in
                    HStack(spacing: 8) {
                        SewnPill(text: kind.name, tint: EntityNodeView.hue(for: kind.name))
                        Text(kind.description)
                            .font(.sewnSans(11))
                            .foregroundStyle(Color.sewnInk.opacity(0.6))
                        Spacer()
                        Button {
                            policy?.kinds.removeAll { $0.name == kind.name }
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.sewnInk.opacity(0.3))
                    }
                }
                HStack(spacing: 8) {
                    TextField("kind", text: $newKindName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                    TextField("description", text: $newKindDescription)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") {
                        let name = newKindName.trimmingCharacters(in: .whitespaces).lowercased()
                        guard !name.isEmpty, policy?.kinds.contains(where: { $0.name == name }) != true else { return }
                        policy?.kinds.append(.init(name: name, description: newKindDescription))
                        newKindName = ""; newKindDescription = ""
                    }
                    .buttonStyle(.sewnQuiet)
                }
            }
        }
    }

    private var promptSection: some View {
        SewnCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Extraction prompt template")
                Text("Leave empty for the built-in prompt. Placeholders: {{kinds}}, {{kind_names}}, {{max_entities}}, {{max_relationships}}")
                    .font(.sewnSans(10.5))
                    .foregroundStyle(Color.sewnInk.opacity(0.45))
                TextEditor(text: Binding(
                    get: { policy?.promptTemplate ?? "" },
                    set: { policy?.promptTemplate = $0.isEmpty ? nil : $0 }
                ))
                .font(.sewnMono(11))
                .frame(height: 110)
                .scrollContentBackground(.hidden)
                .background(Color.white.opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 14) {
                    Stepper("max entities: \(policy?.maxEntities ?? 0)", value: Binding(
                        get: { policy?.maxEntities ?? 12 },
                        set: { policy?.maxEntities = $0 }), in: 1...50)
                    Stepper("max relationships: \(policy?.maxRelationships ?? 0)", value: Binding(
                        get: { policy?.maxRelationships ?? 15 },
                        set: { policy?.maxRelationships = $0 }), in: 0...80)
                }
                .font(.sewnSans(11))
            }
        }
    }

    private var aliasSection: some View {
        SewnCard {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Predicate aliases")
                ForEach((policy?.predicateAliases ?? [:]).sorted(by: { $0.key < $1.key }), id: \.key) { alias, canonical in
                    HStack(spacing: 6) {
                        Text(alias).font(.sewnMono(10.5))
                        Image(systemName: "arrow.right").font(.system(size: 9))
                            .foregroundStyle(Color.sewnGold)
                        Text(canonical).font(.sewnMono(10.5))
                        Spacer()
                        Button {
                            policy?.predicateAliases.removeValue(forKey: alias)
                        } label: {
                            Image(systemName: "xmark.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.sewnInk.opacity(0.3))
                    }
                }
                HStack(spacing: 8) {
                    TextField("alias (e.g. works for)", text: $newAliasFrom)
                        .textFieldStyle(.roundedBorder)
                    Image(systemName: "arrow.right").font(.system(size: 10))
                    TextField("canonical (e.g. employed by)", text: $newAliasTo)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") {
                        let from = newAliasFrom.trimmingCharacters(in: .whitespaces).lowercased()
                        let to = newAliasTo.trimmingCharacters(in: .whitespaces).lowercased()
                        guard !from.isEmpty, !to.isEmpty else { return }
                        policy?.predicateAliases[from] = to
                        newAliasFrom = ""; newAliasTo = ""
                    }
                    .buttonStyle(.sewnQuiet)
                }
            }
        }
    }

    private var autoEdgeSection: some View {
        SewnCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Auto-edges — in-flight edge creation")

                Toggle(isOn: Binding(
                    get: { policy?.coMention?.enabled ?? false },
                    set: { enabled in
                        if policy?.coMention == nil {
                            policy?.coMention = .init(enabled: enabled, predicate: "appears with",
                                                      skipExplicitlyLinked: true)
                        } else {
                            policy?.coMention?.enabled = enabled
                        }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Co-mention edges").font(.sewnSans(12, weight: .medium))
                        Text("Entities extracted from the same document link with a weighted auto:appears-with edge.")
                            .font(.sewnSans(10.5)).foregroundStyle(Color.sewnInk.opacity(0.5))
                    }
                }

                Toggle(isOn: Binding(
                    get: { policy?.similarity?.enabled ?? false },
                    set: { enabled in
                        if policy?.similarity == nil {
                            policy?.similarity = .init(enabled: enabled, cosineThreshold: 0.82,
                                                       maxEdgesPerEntity: 3, predicate: "related to")
                        } else {
                            policy?.similarity?.enabled = enabled
                        }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Similarity edges").font(.sewnSans(12, weight: .medium))
                        Text("New entities bridge to semantically-close existing entities (auto:related-to) via embedding cosine.")
                            .font(.sewnSans(10.5)).foregroundStyle(Color.sewnInk.opacity(0.5))
                    }
                }

                if policy?.similarity?.enabled == true {
                    HStack(spacing: 14) {
                        Text("cosine ≥ \(String(format: "%.2f", policy?.similarity?.cosineThreshold ?? 0.82))")
                            .font(.sewnMono(10.5))
                        Slider(value: Binding(
                            get: { policy?.similarity?.cosineThreshold ?? 0.82 },
                            set: { policy?.similarity?.cosineThreshold = $0 }
                        ), in: 0.5...0.99)
                        .frame(width: 160)
                        Stepper("max edges/entity: \(policy?.similarity?.maxEdgesPerEntity ?? 3)", value: Binding(
                            get: { policy?.similarity?.maxEdgesPerEntity ?? 3 },
                            set: { policy?.similarity?.maxEdgesPerEntity = $0 }), in: 1...10)
                            .font(.sewnSans(11))
                    }
                    .padding(.leading, 20)
                }

                Stepper("hub degree cap: \(policy?.hubDegreeCap ?? 0)", value: Binding(
                    get: { policy?.hubDegreeCap ?? 24 },
                    set: { policy?.hubDegreeCap = $0 }), in: 4...200, step: 4)
                    .font(.sewnSans(11))
                Text("Entities at/over this degree receive no new auto-edges (megahub guard). Policy changes apply to future ingests — use per-document re-extract for existing data.")
                    .font(.sewnSans(10.5))
                    .foregroundStyle(Color.sewnInk.opacity(0.5))
            }
        }
    }

    // MARK: Load / save

    private func load() async {
        guard let api = viewModel.api else {
            status = "no Thread selected"
            return
        }
        do {
            policy = try await api.policy()
        } catch {
            status = error.localizedDescription
        }
    }

    private func save() {
        guard let api = viewModel.api, let policy else { return }
        Task {
            do {
                self.policy = try await api.updatePolicy(policy)
                status = "saved"
            } catch {
                status = error.localizedDescription
            }
        }
    }
}
