import SwiftUI

/// The Graph pane: compact query rows → canvas with an overlay entity
/// inspector, plus the search-trace overlay for debugging retrieval. Lives as
/// the toggleable right pane of the Workspace, which owns the view model.
struct GraphPane: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var viewModel: GraphViewModel

    var body: some View {
        VStack(spacing: 0) {
            queryBar
            Divider().overlay(Color.seerBorder)

            if viewModel.target == nil {
                EmptyHero(title: "Knowledge Graph",
                          subtitle: "Pick a Totem above (start one from the Servers screen, or switch to Prod), then query its graph by entity name or free text.")
            } else if viewModel.nodes.isEmpty {
                EmptyHero(title: viewModel.isLoading ? "Querying…" : "No entities",
                          subtitle: viewModel.error
                              ?? "Query by entity name or free text — ingest documents first if the graph is empty.")
            } else {
                ZStack(alignment: .trailing) {
                    GraphCanvas(viewModel: viewModel)
                    if viewModel.selectedEntityId != nil {
                        EntityDetailPanel(viewModel: viewModel)
                            .frame(width: 280)
                            .background(Color.seerBG)
                            .overlay(alignment: .leading) {
                                Divider().overlay(Color.seerBorder)
                            }
                            .transition(.move(edge: .trailing))
                    }
                }
            }

            traceBar
        }
        .background(Color.seerBG)
        .onAppear { syncTotemSelection() }
        .onReceive(appState.servers.$totemConfigs) { _ in syncTotemSelection() }
        .onReceive(appState.servers.$environment) { _ in syncTotemSelection() }
        .onReceive(appState.servers.$discoveredTotems) { _ in syncTotemSelection() }
        // Auto-load the full graph (browse mode) whenever a target is attached
        // and nothing is on the canvas yet — no manual query needed.
        .task(id: viewModel.target?.id) {
            if viewModel.target != nil, viewModel.nodes.isEmpty {
                await viewModel.fetch()
            }
        }
        .sheet(isPresented: Binding(
            get: { viewModel.renamingEntityId != nil },
            set: { if !$0 { viewModel.renamingEntityId = nil } }
        )) {
            RenameEntitySheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showPolicyEditor) {
            PolicyEditorView(viewModel: viewModel)
                .frame(minWidth: 620, minHeight: 560)
        }
    }

    @State private var showPolicyEditor = false

    private func syncTotemSelection() {
        let targets = appState.servers.totemTargets
        // Re-sync when the current target vanished (e.g. environment switch).
        if let current = viewModel.target, targets.contains(where: { $0.id == current.id }) {
            return
        }
        if let first = targets.first {
            select(target: first)
        } else {
            viewModel.target = nil
        }
    }

    private func select(target: TotemTarget) {
        viewModel.attach(
            target: target,
            ownerId: UserDefaults.standard.string(forKey: "seer.client.ownerId")
                ?? KeychainStore.get("user_id") ?? ""
        )
    }

    // MARK: Query bar

    private var queryBar: some View {
        PaneHeader {
            HStack(spacing: 8) {
                SectionLabel("Graph")

                Picker("", selection: Binding(
                    get: { viewModel.target?.id },
                    set: { id in
                        if let target = appState.servers.totemTargets.first(where: { $0.id == id }) {
                            select(target: target)
                        }
                    }
                )) {
                    ForEach(appState.servers.totemTargets) { target in
                        Text(target.label).tag(String?.some(target.id))
                    }
                }
                .frame(minWidth: 90, maxWidth: 150)

                Spacer(minLength: 8)

                Button {
                    showPolicyEditor = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.seerIcon)
                .disabled(viewModel.target == nil)
                .help("Extraction policy")
            }

            // Row minimums must fit the pane minimum (360 − 32 padding):
            // 60 + 70 + stepper ~85 + Query ~64 + 3×8 spacing ≈ 303.
            HStack(spacing: 8) {
                TextField("entity…", text: $viewModel.entityQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 60, maxWidth: 120)
                    .onSubmit { Task { await viewModel.fetch() } }

                TextField("free text…", text: $viewModel.textQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 70)
                    .onSubmit { Task { await viewModel.fetch() } }

                Stepper("hops \(viewModel.hops)", value: $viewModel.hops, in: 0...3)
                    .font(.seerSans(11))

                Button("Query") { Task { await viewModel.fetch() } }
                    .buttonStyle(.seer)
            }
        }
    }

    // MARK: Trace bar

    private var traceBar: some View {
        PaneFooter {
            SectionLabel("Trace")
            TextField("test search…", text: $viewModel.traceQuery)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 60)
                .onSubmit { Task { await viewModel.runTrace() } }
            Button("Trace") { Task { await viewModel.runTrace() } }
                .buttonStyle(.seerQuiet)
            if viewModel.traceActive {
                SeerPill(text: "\(viewModel.traceMatchedIds.count)m · \(viewModel.traceExpansionEdgeIds.count)x")
                Button("Clear") { viewModel.clearTrace() }
                    .buttonStyle(.seerQuiet)
            }
            if let stats = viewModel.stats {
                Spacer(minLength: 4)
                SeerPill(text: "\(stats.entityCount)e · \(stats.relationshipCount)r")
            }
        }
    }
}

// MARK: - Detail panel

struct EntityDetailPanel: View {
    @ObservedObject var viewModel: GraphViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Spacer()
                    Button {
                        viewModel.selectedEntityId = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.seerIcon)
                    .help("Close inspector")
                }
                if let entity = viewModel.selectedEntity {
                    entityDetail(entity)
                } else {
                    SectionLabel("Documents")
                    ForEach(viewModel.documents) { document in
                        documentRow(document)
                    }
                    if viewModel.documents.isEmpty {
                        Text("Select an entity, or query with documents included.")
                            .font(.seerSans(11))
                            .foregroundStyle(Color.seerInk.opacity(0.4))
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.seerBG)
    }

    @ViewBuilder
    private func entityDetail(_ entity: GraphEntity) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(entity.name)
                .font(.seerSerif(19, weight: .light, italic: true))
                .foregroundStyle(Color.seerInk)
            HStack(spacing: 6) {
                SeerPill(text: entity.kind, tint: EntityNodeView.hue(for: entity.kind))
                if let mentions = entity.mentionCount {
                    SeerPill(text: "\(mentions) mention\(mentions == 1 ? "" : "s")")
                }
            }
        }

        Divider().overlay(Color.seerBorder)

        SectionLabel("Relationships")
        let incident = viewModel.edges.filter {
            $0.relationship.subjectId == entity.id || $0.relationship.objectId == entity.id
        }
        if incident.isEmpty {
            Text("none in view")
                .font(.seerSans(11))
                .foregroundStyle(Color.seerInk.opacity(0.4))
        }
        ForEach(incident) { edge in
            relationshipRow(edge.relationship, from: entity)
                .contextMenu {
                    Button("Delete relationship", role: .destructive) {
                        viewModel.delete(relationshipId: edge.id)
                    }
                }
        }

        Divider().overlay(Color.seerBorder)

        SectionLabel("Provenance")
        ForEach(entity.documentIds ?? [], id: \.self) { documentId in
            HStack(spacing: 6) {
                Text(documentId)
                    .font(.seerMono(9))
                    .foregroundStyle(Color.seerInk.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    viewModel.reExtract(documentId: documentId)
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.seerGold)
                .help("Re-extract this document with the current policy")
            }
        }
    }

    private func relationshipRow(_ relationship: GraphRelationship, from entity: GraphEntity) -> some View {
        let outgoing = relationship.subjectId == entity.id
        let otherId = outgoing ? relationship.objectId : relationship.subjectId
        let otherName = viewModel.nodes.first { $0.id == otherId }?.entity.name ?? String(otherId.prefix(10))
        return HStack(spacing: 5) {
            Image(systemName: outgoing ? "arrow.right" : "arrow.left")
                .font(.system(size: 9))
                .foregroundStyle(Color.seerGold)
            Text(relationship.predicate)
                .font(.seerMono(10))
                .foregroundStyle(Color.seerInk.opacity(0.6))
            Text(otherName)
                .font(.seerSans(11, weight: .medium))
                .foregroundStyle(Color.seerInk)
            Spacer()
            if let weight = relationship.weight, weight > 1 {
                SeerPill(text: "×\(weight)")
            }
        }
    }

    private func documentRow(_ document: GraphDocument) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(document.name ?? String(document.id.prefix(16)))
                .font(.seerSans(11.5, weight: .medium))
                .foregroundStyle(Color.seerInk)
                .lineLimit(1)
            Text(document.ownerId ?? "")
                .font(.seerMono(9))
                .foregroundStyle(Color.seerInk.opacity(0.4))
                .lineLimit(1)
        }
        .padding(.vertical, 3)
    }
}
