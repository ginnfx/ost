// Pure validation rule for the Add-OST form, extracted from AddOstView so it
// can be unit tested without a view/store round-trip. Mirrors AddOstView's
// `canSubmit` exactly — keep the two in sync.

import Foundation

enum AddOstRules {
    /// Submitter is REQUIRED: an OST nobody clearly owns breaks the
    /// competition (no self-rating seed, invisible under every person
    /// filter). Checking roster membership (not just non-nil) also covers
    /// the person being deleted while the sheet is open.
    nonisolated static func canSubmit(
        title: String, submitterID: Int?, people: [Person], isSubmitting: Bool,
        hasHistoryConflict: Bool = false
    ) -> Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && people.contains { $0.id == submitterID }
            && !isSubmitting
            && !hasHistoryConflict
    }

    /// Client-side mirror of `history_repo.entry_matches` in the Python
    /// domain layer — the authority for what counts as a duplicate; this is
    /// only a live pre-submit hint (the backend 400 on POST /osts is the
    /// real enforcement), so exotic-Unicode casing divergence is harmless.
    /// A duplicate is the same track: titles match, and sources match
    /// unless either side's source is unknown (blank matches anything).
    nonisolated static func historyConflict(
        title: String, source: String, history: [HistoryEntry]
    ) -> HistoryEntry? {
        let normTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normTitle.isEmpty else { return nil }
        let normSource = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return history.first { entry in
            guard entry.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normTitle
            else { return false }
            let entrySource = (entry.source ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return entrySource.isEmpty || normSource.isEmpty || entrySource == normSource
        }
    }
}
