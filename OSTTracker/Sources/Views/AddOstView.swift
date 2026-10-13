// Add-OST form (sheet). Fields map 1:1 to POST /osts; the submitter auto-10
// self-rating and cover art fetch both happen server-side on create — no
// business logic here. Cover is auto-fetched in the background after add.

import SwiftUI

struct AddOstView: View {
    let store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var source = ""
    @State private var submitterID: Int?
    @State private var link = ""
    @State private var submitting = false
    @State private var historyConflict: HistoryEntry?
    @FocusState private var sourceFocused: Bool

    /// Defaults the submitter to the roster's active person filter, so adding an
    /// OST while filtered by someone attributes it to them automatically.
    /// The filter can outlive the person it points at (deleted between the
    /// filter being captured and this sheet opening) — only seed a default
    /// that still resolves to a real roster entry.
    init(store: AppStore, defaultSubmitterID: Int? = nil,
         initialTitle: String = "", initialSource: String = "", initialLink: String = "") {
        self.store = store
        let validDefault = store.people.contains { $0.id == defaultSubmitterID } ? defaultSubmitterID : nil
        _submitterID = State(initialValue: validDefault)
        _title = State(initialValue: initialTitle)
        _source = State(initialValue: initialSource)
        _link = State(initialValue: initialLink)
    }

    // Delegates to AddOstRules (see that type for the rule rationale) so the
    // validation logic is unit-testable without a view/store round-trip.
    private var canSubmit: Bool {
        AddOstRules.canSubmit(
            title: title, submitterID: submitterID, people: store.people, isSubmitting: submitting,
            hasHistoryConflict: historyConflict != nil
        )
    }

    /// Any typed content worth protecting from an accidental dismissal.
    private var isDirty: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            || !source.trimmingCharacters(in: .whitespaces).isEmpty
            || !link.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Distinct sources matching what's typed — franchise autofill for repeats.
    private var sourceSuggestions: [String] {
        let query = source.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return [] }
        return store.distinctSources
            .filter { $0.lowercased() != query && $0.lowercased().contains(query) }
            .prefix(6)
            .map { $0 }
    }

    var body: some View {
        Group {
            #if os(iOS)
            ScrollView { formContent }
                .presentationDetents([.large])
            #else
            formContent
            #endif
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(isDirty)
        .task(id: "\(title)\u{1}\(source)") {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            historyConflict = AddOstRules.historyConflict(title: title, source: source, history: store.history)
        }
    }

    private var formContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("ADD OST")
                .font(.ostDisplay(18, weight: .bold))
                .foregroundStyle(Theme.accent)

            field("Title", text: $title, placeholder: "Track title")
            if let historyConflict {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.rust)
                    Text(historyConflictMessage(historyConflict))
                        .font(.ostBody(11)).foregroundStyle(Theme.rust)
                }
            }
            sourceField

            if store.people.isEmpty {
                // The submitter requirement is unsatisfiable with no roster —
                // tell the user why Add is stuck instead of a silent dead end.
                HStack(spacing: 4) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .foregroundStyle(Theme.rust)
                    Text("Add someone in People before adding an OST.")
                        .font(.ostBody(11)).foregroundStyle(Theme.textDim)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Text("Submitted by").font(.ostDisplay(11)).foregroundStyle(Theme.textDim)
                        Text("required").font(.ostMono(9)).foregroundStyle(Theme.rust)
                    }
                    Picker("", selection: $submitterID) {
                        // Placeholder only — Add stays disabled until a person is chosen.
                        Text("Choose a person").tag(Int?.none)
                        ForEach(store.people) { person in
                            Text(person.name).tag(Int?.some(person.id))
                        }
                    }
                    .labelsHidden()
                    .tint(Theme.accent)
                }
            }

            field("External link", text: $link, placeholder: "YouTube / Spotify URL (optional)")

            Text("Cover art is fetched after adding. The submitter gets a score of 10.")
                .font(.ostBody(11)).foregroundStyle(Theme.textDim)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                    .font(.ostDisplay(12, weight: .semibold))
                Button("Add") { submit() }
                    .buttonStyle(.borderedProminent)
                    .font(.ostDisplay(13, weight: .semibold))
                    .disabled(!canSubmit)
            }
        }
        .padding(28)
        #if os(iOS)
        .frame(maxWidth: 420)
        #else
        .frame(width: 420)
        #endif
    }

    private func historyConflictMessage(_ entry: HistoryEntry) -> String {
        var detail = entry.batchLabel ?? "a past ranking"
        if let sender = entry.sender { detail += " (submitted by \(sender))" }
        return "Already in \(detail)."
    }

    // Source field with a franchise-autofill dropdown: as you type, distinct
    // sources you've used before that match are offered; tap one to fill it in.
    private var sourceField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Source").font(.ostDisplay(11)).foregroundStyle(Theme.textDim)
            TextField("Game / anime / media", text: $source)
                .textFieldStyle(.plain)
                .font(.ostBody(14))
                .padding(8)
                .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 7))
                .focused($sourceFocused)
            if sourceFocused, !sourceSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(sourceSuggestions, id: \.self) { suggestion in
                        Button {
                            source = suggestion
                            sourceFocused = false
                        } label: {
                            Text(suggestion)
                                .font(.ostBody(13))
                                .foregroundStyle(Theme.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                // Dark tint keeps the suggestion rows legible over whatever the
                // sheet's automatic glass happens to refract behind them.
                .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 7))
            }
        }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.ostDisplay(11)).foregroundStyle(Theme.textDim)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.ostBody(14))
                .padding(8)
                .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private func submit() {
        guard canSubmit else { return }
        let t = title.trimmingCharacters(in: .whitespaces)
        submitting = true
        let s = source.trimmingCharacters(in: .whitespaces)
        let l = link.trimmingCharacters(in: .whitespaces)
        Task {
            let added = await store.addOst(
                title: t,
                source: s.isEmpty ? nil : s,
                submitterID: submitterID,
                link: l.isEmpty ? nil : l
            )
            // Only celebrate a confirmed add. On failure the sheet stays open
            // for a retry (the store's error banner explains what happened).
            if added {
                SoundKit.shared.play(.added)
                dismiss()
            } else {
                submitting = false
            }
        }
    }
}
