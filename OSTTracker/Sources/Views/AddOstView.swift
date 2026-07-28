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
    /// OST while filtered by someone attributes it to them out of the box.
    /// The filter can outlive the person it points at (deleted between the
    /// filter being captured and this sheet opening) — only seed a default
    /// that still resolves to a real roster entry.
    init(store: AppStore, defaultSubmitterID: Int? = nil) {
        self.store = store
        let validDefault = store.people.contains { $0.id == defaultSubmitterID } ? defaultSubmitterID : nil
        _submitterID = State(initialValue: validDefault)
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
                    Text("No people yet — add everyone on the People tab first.")
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
                        Text("— choose a person —").tag(Int?.none)
                        ForEach(store.people) { person in
                            Text(person.name).tag(Int?.some(person.id))
                        }
                    }
                    .labelsHidden()
                    .tint(Theme.accent)
                }
            }

            field("External link", text: $link, placeholder: "YouTube / Spotify URL (optional)")

            Text("Cover art is fetched automatically after adding. The submitter is auto-scored 10 (self-rating).")
                .font(.ostBody(11)).foregroundStyle(Theme.textDim)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.glass)
                    .font(.ostDisplay(12, weight: .semibold))
                Button("Add") { submit() }
                    .buttonStyle(.glass)
                    .tint(canSubmit ? Theme.accent : Theme.textDim)
                    .font(.ostDisplay(13, weight: .semibold))
                    .disabled(!canSubmit)
            }
        }
        .padding(28)
        .frame(width: 420)
        // No custom background here: the sheet receives automatic Liquid Glass
        // from the macOS 26+ SDK. A .background(.ultraThinMaterial) or any solid
        // fill would override that glass — keep this view background-free.
        .preferredColorScheme(.dark)
        // RootView presents this via .sheet(item:), giving each open a fresh
        // identity so the submitter-filter default is re-honored every time —
        // but that also means an accidental Escape/click-outside destroys a
        // half-typed form with no undo. Block dismissal while dirty; Cancel
        // still calls dismiss() directly so it keeps working either way.
        .interactiveDismissDisabled(isDirty)
        // Debounced live pre-submit hint, checked locally against the
        // already-loaded store.history (no network round trip — see
        // AddOstRules.historyConflict, which mirrors the backend's match
        // rule). The task is cancelled and restarted on every keystroke of
        // either field (via id:); the short sleep only smooths the warning
        // banner from flickering mid-word. The backend's 400 is the real
        // enforcement — this is a proactive UX nicety only.
        .task(id: "\(title)\u{1}\(source)") {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            historyConflict = AddOstRules.historyConflict(title: title, source: source, history: store.history)
        }
    }

    private func historyConflictMessage(_ entry: HistoryEntry) -> String {
        var detail = entry.batchLabel ?? "a past ranking"
        if let sender = entry.sender { detail += " (submitted by \(sender))" }
        return "Already used before, in \(detail)."
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
                .glassEffect(.regular, in: ChamferedRect(cut: 8))
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
                .glassEffect(.regular.tint(Color.black.opacity(0.25)), in: ChamferedRect(cut: 8))
                .overlay(ChamferedRect(cut: 8).stroke(Theme.accent.opacity(0.3), lineWidth: 1))
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
                .glassEffect(.regular, in: ChamferedRect(cut: 8))
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
