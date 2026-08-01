// Read-only list of every OST ever ranked, past or current — the exclusion
// list Add-OST checks against. All data (title/source/batch/sender) arrives
// precomputed from Python; this view only displays and client-side filters
// what's already loaded in the store.

import SwiftUI

struct HistoryView: View {
    let store: AppStore
    @State private var search = ""
    @State private var debouncedSearch = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        if store.history.isEmpty {
            ContentUnavailableView(
                "No history yet", systemImage: "clock.arrow.circlepath",
                description: Text("Every OST ever ranked will be tracked here so it's never repeated.")
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    searchField

                    if groupedHistory.isEmpty {
                        Text("No matches for \"\(debouncedSearch)\".")
                            .font(.ostBody(13)).foregroundStyle(Theme.textDim)
                            .padding(.top, 40)
                            .frame(maxWidth: .infinity)
                    } else {
                        ForEach(groupedHistory, id: \.label) { group in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(group.label.uppercased())
                                    .font(.ostDisplay(13, weight: .semibold))
                                    .foregroundStyle(Theme.accent)

                                LazyVGrid(
                                    columns: [GridItem(.adaptive(minimum: 240, maximum: 340), spacing: Theme.gridSpacing)],
                                    spacing: Theme.gridSpacing
                                ) {
                                    ForEach(group.entries) { entry in
                                        HistoryCard(entry: entry)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 90)   // clear the now-playing bar
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.textDim)
            TextField("Search title, source, or sender…", text: $search)
                .textFieldStyle(.plain).font(.ostBody(13))
                .focused($searchFocused)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .glassEffect(.regular, in: ChamferedRect(cut: 8))
        .frame(maxWidth: searchFocused || !search.isEmpty ? 320 : 240)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: searchFocused)
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

    /// Filtered entries grouped by batch label, most recent ranking first
    /// (Current Ranking, then Batch N descending). Purely a display ordering —
    /// no business rule lives here.
    private var groupedHistory: [(label: String, entries: [HistoryEntry])] {
        let query = debouncedSearch.trimmingCharacters(in: .whitespaces)
        let filtered = query.isEmpty ? store.history : store.history.filter { entry in
            entry.title.localizedCaseInsensitiveContains(query)
                || (entry.source?.localizedCaseInsensitiveContains(query) ?? false)
                || (entry.sender?.localizedCaseInsensitiveContains(query) ?? false)
        }
        var byLabel: [String: [HistoryEntry]] = [:]
        for entry in filtered {
            byLabel[entry.batchLabel ?? "Unlabeled", default: []].append(entry)
        }
        return byLabel
            .map { (label: $0.key, entries: $0.value.sorted { $0.title.lowercased() < $1.title.lowercased() }) }
            .sorted { Self.recencyKey(for: $0.label) > Self.recencyKey(for: $1.label) }
    }

    /// Mirrors ost_repo.CURRENT_RANKING_LABEL on the Python side — the batch
    /// label every OST in the live, in-progress ranking is recorded under.
    private static let currentRankingLabel = "Current Ranking"

    /// Higher = more recent. "Current Ranking" always sorts first; batch
    /// labels sort by their leading number ("Batch 4: …" > "Batch 1: …").
    private static func recencyKey(for label: String) -> Int {
        if label == currentRankingLabel { return .max }
        guard label.hasPrefix("Batch "),
              let numberPart = label.dropFirst("Batch ".count).split(separator: ":").first,
              let n = Int(numberPart)
        else { return 0 }
        return n
    }
}

private struct HistoryCard: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.title)
                .font(.ostBody(14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
            if let source = entry.source, !source.isEmpty {
                Text(source)
                    .font(.ostBody(12))
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
            }
            if let sender = entry.sender, !sender.isEmpty {
                Text(sender)
                    .font(.ostMono(11))
                    .foregroundStyle(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(ChamferedRect().fill(Theme.cardSurface))
        .overlay(ChamferedRect().stroke(Theme.accent.opacity(0.2), lineWidth: 1))
    }
}
