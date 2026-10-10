// Every OST ever ranked, past or current. Ranking headings can be renamed;
// the backend updates the entire history group and linked retired round.

import SwiftUI

struct HistoryView: View {
    let store: AppStore
    @State private var search = ""
    @State private var debouncedSearch = ""
    @State private var renameTarget: HistoryRenameTarget?
    @State private var proposedName = ""
    @State private var isSavingName = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        if store.history.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("History")
                    .font(.ostDisplay(22, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("OSTs appear here as you add them to a ranking.")
                    .font(.ostBody(13))
                    .foregroundStyle(Theme.textDim)
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text("History")
                            .font(.ostDisplay(22, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text("\(store.history.count) OSTs")
                            .font(.ostBody(12))
                            .foregroundStyle(Theme.textDim)
                    }
                    searchField

                    if groupedHistory.isEmpty {
                        Text("No matches for \"\(debouncedSearch)\".")
                            .font(.ostBody(13)).foregroundStyle(Theme.textDim)
                            .padding(.top, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(groupedHistory, id: \.label) { group in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 9) {
                                    Text(group.label)
                                        .font(.ostDisplay(13, weight: .semibold))
                                        .foregroundStyle(Theme.accent)
                                    if group.label == store.roundInfo?.currentName && store.roundInfo?.needsStart == false {
                                        Text("In progress")
                                            .font(.ostBody(11, weight: .medium))
                                            .foregroundStyle(Theme.accent)
                                    }
                                    if group.label != Self.currentRankingLabel && group.label != "Unlabeled" {
                                        Button {
                                            proposedName = group.label
                                            renameTarget = HistoryRenameTarget(label: group.label)
                                        } label: {
                                            Image(systemName: "pencil")
                                                .font(.system(size: 11))
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(Theme.textDim)
                                        .help("Rename ranking")
                                        .accessibilityLabel("Rename \(group.label)")
                                    }
                                }

                                LazyVStack(spacing: 0) {
                                    ForEach(group.entries) { entry in
                                        HistoryCard(entry: entry)
                                    }
                                }
                                .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 7))
                            }
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, bottomClearance)
            }
            .sheet(item: $renameTarget) { target in
                VStack(alignment: .leading, spacing: 16) {
                    Text("Rename ranking").font(.title2.bold())
                    TextField("Ranking name", text: $proposedName)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Cancel") { renameTarget = nil }
                        Spacer()
                        Button("Save name") {
                            isSavingName = true
                            Task {
                                let saved = await store.renameHistoryLabel(from: target.label, to: proposedName)
                                isSavingName = false
                                if saved { renameTarget = nil }
                            }
                        }
                        .disabled(proposedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || proposedName.count > 80 || isSavingName)
                    }
                }
                .padding(24)
                .frame(maxWidth: 420)
            }
        }
    }

    private var bottomClearance: CGFloat {
        #if os(macOS)
        12
        #else
        90
        #endif
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.textDim)
            TextField("Search title, source, or sender…", text: $search)
                .textFieldStyle(.plain).font(.ostBody(13))
                .focused($searchFocused)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 7))
        .frame(maxWidth: searchFocused || !search.isEmpty ? 320 : 240)
        // Debounced so a full filter+group+sort of the history array doesn't
        // run on the main thread every keystroke — same pattern as
        // AddOstView's title debounce, shorter since this is local work.
        .task(id: search) {
            guard !search.isEmpty else { debouncedSearch = ""; return }
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            debouncedSearch = search
        }
    }

    /// Filtered entries grouped by batch label, with the live ranking first.
    /// Purely a display ordering —
    /// no business rule lives here.
    private var groupedHistory: [(label: String, entries: [HistoryEntry])] {
        let query = debouncedSearch.trimmingCharacters(in: .whitespaces)
        let filtered = query.isEmpty ? store.history : store.history.filter { entry in
            entry.title.localizedCaseInsensitiveContains(query)
                || (entry.source?.localizedCaseInsensitiveContains(query) ?? false)
                || (entry.sender?.localizedCaseInsensitiveContains(query) ?? false)
                || (entry.batchLabel?.localizedCaseInsensitiveContains(query) ?? false)
        }
        var byLabel: [String: [HistoryEntry]] = [:]
        for entry in filtered {
            byLabel[entry.batchLabel ?? "Unlabeled", default: []].append(entry)
        }
        return byLabel
            .map { (label: $0.key, entries: $0.value.sorted { $0.title.lowercased() < $1.title.lowercased() }) }
            .sorted { recencyKey(for: $0) > recencyKey(for: $1) }
    }

    /// Mirrors ost_repo.CURRENT_RANKING_LABEL on the Python side — the batch
    /// label every OST in the live, in-progress ranking is recorded under.
    private static let currentRankingLabel = "Current Ranking"

    /// Entry IDs keep the ranking order stable even after its label changes.
    private func recencyKey(for group: (label: String, entries: [HistoryEntry])) -> Int {
        if group.label == store.roundInfo?.currentName && store.roundInfo?.needsStart == false { return .max }
        return group.entries.map(\.id).max() ?? 0
    }
}

private struct HistoryRenameTarget: Identifiable {
    let label: String
    var id: String { label }
}

private struct HistoryCard: View {
    let entry: HistoryEntry
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 16) {
            Text(entry.title)
                .font(.ostBody(13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let source = entry.source, !source.isEmpty {
                Text(source)
                    .font(.ostBody(12))
                    .foregroundStyle(Theme.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let sender = entry.sender, !sender.isEmpty {
                Text(sender)
                    .font(.ostBody(11))
                    .foregroundStyle(Theme.textDim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(isHovered ? Theme.cardSurface : Theme.bgRaised)
        .overlay(alignment: .bottom) { Theme.separator.frame(height: 1) }
        .onHover { isHovered = $0 }
    }
}
