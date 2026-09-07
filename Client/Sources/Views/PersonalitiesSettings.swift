import SwiftUI

/// Settings card for managing chat personalities: list, edit, add, and save
/// back to the server (`PUT /v1/admin/personalities`). Requires sign-in.
struct PersonalitiesSection: View {
    @EnvironmentObject private var appState: AppState

    @State private var personalities: [Personality] = []
    @State private var editing: Personality?
    @State private var isLoading = false
    @State private var status: String?
    @State private var isDirty = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel("Personalities")
                Spacer()
                if isDirty {
                    Button("Save to server") { save() }
                        .buttonStyle(.sewn)
                }
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.sewnQuiet)
            }

            Text("Personas for chat: a voice fragment, generation parameters, and an optional fine-tuned model. Citation emphasis strengthens the source-marker discipline for that persona.")
                .font(.sewnSans(11))
                .foregroundStyle(Color.sewnInk.opacity(0.45))

            if personalities.isEmpty && !isLoading {
                Text("Sign in and refresh to load personalities.")
                    .font(.sewnSans(11))
                    .foregroundStyle(Color.sewnInk.opacity(0.45))
            }

            ForEach(personalities) { personality in
                personalityRow(personality)
            }

            HStack {
                Button {
                    let new = Personality(
                        id: "persona-\(personalities.count + 1)",
                        name: "New persona",
                        tagline: "",
                        systemFragment: "",
                        citationEmphasis: false,
                        temperature: nil,
                        topP: nil,
                        modelOverride: nil
                    )
                    personalities.append(new)
                    editing = new
                    isDirty = true
                } label: {
                    Label("Add personality", systemImage: "plus")
                }
                .buttonStyle(.sewnQuiet)
                if let status {
                    Text(status)
                        .font(.sewnSans(11))
                        .foregroundStyle(status.hasPrefix("Saved")
                            ? Color.sewnGreen : Color.sewnError)
                }
            }
        }
        .task { await load() }
        .sheet(item: $editing) { personality in
            PersonalityEditorSheet(
                personality: personality,
                onSave: { updated in
                    if let index = personalities.firstIndex(where: { $0.id == personality.id }) {
                        personalities[index] = updated
                    }
                    isDirty = true
                    editing = nil
                },
                onCancel: { editing = nil }
            )
        }
    }

    private func personalityRow(_ personality: Personality) -> some View {
        HStack(spacing: 8) {
            Text(personality.name)
                .font(.sewnSans(12, weight: .medium))
                .foregroundStyle(Color.sewnInk)
                .frame(width: 90, alignment: .leading)
                .fixedSize()
            Text(personality.tagline)
                .font(.sewnSans(11))
                .foregroundStyle(Color.sewnInk.opacity(0.5))
                .lineLimit(1)
            Spacer(minLength: 8)
            if personality.citationEmphasis {
                SewnPill(text: "cites")
            }
            if let model = personality.modelOverride {
                SewnPill(text: String(model.suffix(24)))
                    .lineLimit(1)
            }
            Button("Edit") { editing = personality }
                .buttonStyle(.sewnQuiet)
            Button {
                personalities.removeAll { $0.id == personality.id }
                isDirty = true
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.sewnInk.opacity(0.3))
            .disabled(personalities.count <= 1)
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            personalities = try await appState.sewnAPI.personalities()
            isDirty = false
            status = nil
        } catch {
            status = error.localizedDescription
        }
    }

    private func save() {
        status = nil
        Task {
            do {
                personalities = try await appState.sewnAPI.updatePersonalities(personalities)
                isDirty = false
                status = "Saved."
            } catch {
                status = error.localizedDescription
            }
        }
    }
}

// MARK: - Editor sheet

private struct PersonalityEditorSheet: View {
    @State var personality: Personality
    let onSave: (Personality) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit personality")
                .font(.sewnSerif(18, weight: .light, italic: true))
                .foregroundStyle(Color.sewnInk)

            fieldRow("Id") {
                TextField("scholar", text: $personality.id)
                    .textFieldStyle(.roundedBorder)
                    .font(.sewnMono(11))
            }
            fieldRow("Name") {
                TextField("Scholar", text: $personality.name)
                    .textFieldStyle(.roundedBorder)
            }
            fieldRow("Tagline") {
                TextField("Precise and citation-forward", text: $personality.tagline)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                SectionLabel("Voice (system fragment)")
                TextEditor(text: $personality.systemFragment)
                    .font(.sewnSans(12))
                    .frame(height: 110)
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.sewnBorder, lineWidth: 1))
            }

            Toggle("Citation emphasis — stronger [[n]] marker discipline", isOn: $personality.citationEmphasis)
                .font(.sewnSans(12))

            fieldRow("Temperature") {
                slider(value: $personality.temperature, range: 0...1.5, default: 0.8)
            }
            fieldRow("Top-p") {
                slider(value: $personality.topP, range: 0.1...1.0, default: 1.0)
            }
            fieldRow("Model") {
                TextField("tinker://… (optional override)", text: Binding(
                    get: { personality.modelOverride ?? "" },
                    set: { personality.modelOverride = $0.isEmpty ? nil : $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(.sewnMono(11))
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.sewnQuiet)
                Button("Apply") { onSave(personality) }
                    .buttonStyle(.sewn)
                    .disabled(personality.id.isEmpty || personality.name.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(Color.sewnBG)
    }

    private func fieldRow(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.sewnSans(12, weight: .medium))
                .foregroundStyle(Color.sewnInk)
                .frame(width: 90, alignment: .leading)
                .fixedSize()
            content()
        }
    }

    /// Optional-backed slider: nil means "inherit" (tone/defaults decide).
    private func slider(value: Binding<Double?>, range: ClosedRange<Double>, default defaultValue: Double) -> some View {
        HStack(spacing: 8) {
            Slider(value: Binding(
                get: { value.wrappedValue ?? defaultValue },
                set: { value.wrappedValue = $0 }
            ), in: range)
            Text(value.wrappedValue.map { String(format: "%.2f", $0) } ?? "auto")
                .font(.sewnMono(10.5))
                .frame(width: 38, alignment: .trailing)
                .fixedSize()
            Button {
                value.wrappedValue = nil
            } label: {
                Image(systemName: "arrow.uturn.backward.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.sewnInk.opacity(0.3))
            .help("Reset to auto (tone/defaults decide)")
        }
    }
}
