// Ranked artwork grid with searchable entries, batch/slice views, keyboard
// navigation, and an OST detail panel.

import SwiftUI

struct RosterView: View {
    let store: AppStore
    // Owned by RootView so the Add-OST sheet can read the active filter.
    @Binding var submitterFilter: Int?
    @State private var selectedOstID: Int?
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    // Keyboard character-select: roving cursor over the grid (W3C APG roving
    // focus pattern — arrows move, Return opens, Space plays, Esc clears).
    @State private var cursorIndex: Int?
    @FocusState private var gridFocused: Bool
    // Roster ordering: competition rank (default), the private batch key, or the
    // elimination slices. Batch is a host affordance, only offered once batches
    // exist; slices need a ranked board to cut up.
    @State private var sortMode: RosterSort = .rank
    // Data-entry aid: hide anything still missing a score from one of the raters,
    // so what's left on screen is only what still needs typing in. Deliberately
    // ephemeral @State (like `search`) — it's a working view, not a saved one.
    @State private var fullyRatedOnly = false
    @State private var showStartRanking = false
    @State private var newRankingName = ""
    @State private var isStartingRanking = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(Theme.motionKey) private var motionSelection = MotionMode.subtle.rawValue

    private var bottomClearance: CGFloat {
        #if os(macOS)
        12
        #else
        90
        #endif
    }

    private var detailTransition: AnyTransition {
        if reduceMotion || motionSelection == MotionMode.minimal.rawValue { return .identity }
        let scale: CGFloat = motionSelection == MotionMode.cinematic.rawValue ? 0.94 : 0.98
        return .opacity.combined(with: .scale(scale: scale))
    }

    // Tighter minimum on iOS so portrait phones get 2 columns (~160pt each);
    // macOS's wider windows naturally land on more columns at 180pt minimum.
    #if os(iOS)
    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: Theme.gridSpacing)]
    #else
    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 230), spacing: Theme.gridSpacing)]
    #endif
    /// Mirrors EliminationSidebar's fixed frame; the grid subtracts it in slice mode.
    private static let sidebarWidth: CGFloat = 250

    enum RosterSort { case rank, batch, slices }

    /// ost id -> (batchIndex, slot) from the private batch key, for batch sort
    /// + the per-card "B·slot" chip. Empty until the host randomizes.
    private var batchPositions: [Int: (batch: Int, slot: Int)] {
        var out: [Int: (batch: Int, slot: Int)] = [:]
        for group in store.batches {
            for slot in group.slots {
                out[slot.ost.id] = (group.index, slot.slot)
            }
        }
        return out
    }

    /// Display filters over already-loaded data — no store re-architecture. In
    /// batch mode the filtered set is re-ordered by (batch, slot); anything not
    /// yet placed sorts last by title.
    /// How many scores an OST needs to count as fully rated. Everyone in the
    /// roster of people rates everything (DetailView renders one row per person,
    /// submitters included via their seeded self-rating), so a complete card is
    /// one with a score from all of them.
    private var requiredRatings: Int { store.people.count }

    private var displayedEntries: [RankEntry] {
        let required = requiredRatings
        let filtered = store.leaderboard.filter { entry in
            (submitterFilter == nil || entry.ost.submitterId == submitterFilter)
                && (search.isEmpty || entry.ost.title.localizedCaseInsensitiveContains(search))
                && (!fullyRatedOnly || entry.ratingCount >= required)
        }
        switch sortMode {
        case .rank:
            return filtered
        case .batch:
            let positions = batchPositions
            return filtered.sorted { a, b in
                let pa = positions[a.ost.id] ?? (batch: Int.max, slot: Int.max)
                let pb = positions[b.ost.id] ?? (batch: Int.max, slot: Int.max)
                if pa.batch != pb.batch { return pa.batch < pb.batch }
                if pa.slot != pb.slot { return pa.slot < pb.slot }
                return a.ost.title.lowercased() < b.ost.title.lowercased()
            }
        case .slices:
            // Slices are read from the bottom of the table up, so the worst rank
            // leads. Unrated OSTs have no slice and trail by title.
            return filtered.sorted { a, b in
                switch (a.rank, b.rank) {
                case let (ra?, rb?): return ra > rb
                case (nil, _?): return false
                case (_?, nil): return true
                default: return a.ost.title.lowercased() < b.ost.title.lowercased()
                }
            }
        }
    }

    /// Slice mode is only meaningful once Python has ranked something to slice.
    private var hasSlices: Bool { !(store.elimination?.slices.isEmpty ?? true) }

    /// "B1·3"-style chip text for a card, only in batch mode.
    private func batchLabel(for ostID: Int) -> String? {
        guard sortMode == .batch, let pos = batchPositions[ostID] else { return nil }
        return "B\(pos.batch)·\(pos.slot)"
    }

    /// Batch-mode sections: displayedEntries split per batch (unplaced OSTs
    /// last), each entry keeping its flat index so the keyboard-cursor math
    /// still works over the unsectioned list.
    private var batchSections: [(id: Int, title: String, items: [(index: Int, entry: RankEntry)])] {
        let positions = batchPositions
        let dayByBatch = Dictionary(uniqueKeysWithValues: store.batches.map { ($0.index, $0.day) })
        var sections: [(id: Int, title: String, items: [(index: Int, entry: RankEntry)])] = []
        for (index, entry) in displayedEntries.enumerated() {
            let batch = positions[entry.ost.id]?.batch
            let sectionID = batch ?? Int.max
            if sections.last?.id != sectionID {
                let title = batch.map { "DAY \(dayByBatch[$0] ?? $0) · BATCH \($0)" } ?? "UNPLACED"
                sections.append((id: sectionID, title: title, items: []))
            }
            sections[sections.count - 1].items.append((index: index, entry: entry))
        }
        return sections
    }

    /// ost id -> slice index, straight off the server-computed board.
    private var sliceIndexByOst: [Int: Int] {
        var out: [Int: Int] = [:]
        for slice in store.elimination?.slices ?? [] {
            for id in slice.ostIds { out[id] = slice.index }
        }
        return out
    }

    /// Slice-mode sections: displayedEntries (already worst-rank-first) split by
    /// the board's slices, each entry keeping its flat index so the keyboard
    /// cursor math still works over the unsectioned list. A nil slice is the
    /// trailing "UNRATED" group.
    private var sliceSections: [(id: Int, slice: RankSlice?, items: [(index: Int, entry: RankEntry)])] {
        let indexByOst = sliceIndexByOst
        let sliceByIndex = Dictionary(
            uniqueKeysWithValues: (store.elimination?.slices ?? []).map { ($0.index, $0) }
        )
        var sections: [(id: Int, slice: RankSlice?, items: [(index: Int, entry: RankEntry)])] = []
        for (index, entry) in displayedEntries.enumerated() {
            let sectionID = indexByOst[entry.ost.id] ?? Int.max
            if sections.last?.id != sectionID {
                sections.append((id: sectionID, slice: sliceByIndex[sectionID], items: []))
            }
            sections[sections.count - 1].items.append((index: index, entry: entry))
        }
        return sections
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
            VStack(spacing: 0) {
                HStack {
                    Text("Roster")
                        .font(.ostDisplay(22, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 6)
                toolbar
                if store.leaderboard.isEmpty {
                    emptyRoster
                } else if sortMode == .slices, let board = store.elimination {
                    HStack(alignment: .top, spacing: 14) {
                        // The grid keeps the sidebar's width out of its column math.
                        grid(width: geo.size.width - Self.sidebarWidth - 34)
                        EliminationSidebar(board: board)
                            .padding(.top, 20)
                            .padding(.trailing, 20)
                            .padding(.bottom, bottomClearance)
                    }
                } else {
                    grid(width: geo.size.width)
                }
            }
            .allowsHitTesting(selectedOstID == nil)

            if let id = selectedOstID {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .onTapGesture { close() }
                    .transition(.opacity)

                DetailView(store: store, ostID: id, onClose: close)
                    .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.separator, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                .frame(maxWidth: 920, maxHeight: 800)
                .padding(40)
                .zIndex(1)
                .transition(detailTransition)
            }
            }
            .animation(Theme.motion(.detail, reduceMotion: reduceMotion), value: selectedOstID)
            .onChange(of: hasSlices) { _, has in
                // Never strand the picker on an option it no longer offers (e.g.
                // the last rating was cleared away).
                if !has, sortMode == .slices { sortMode = .rank }
            }
        }
        .sheet(isPresented: $showStartRanking) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Start a new ranking").font(.title2.bold())
                Text("People and notes carry over. Scores start fresh. New OSTs appear in History as you add them.")
                    .font(.callout).foregroundStyle(.secondary)
                TextField("e.g. Autumn 2026", text: $newRankingName)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Cancel") { showStartRanking = false }
                    Spacer()
                    Button("Start ranking") {
                        isStartingRanking = true
                        Task {
                            let started = await store.startRound(name: newRankingName)
                            isStartingRanking = false
                            if started { showStartRanking = false; newRankingName = "" }
                        }
                    }
                    .disabled(newRankingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || newRankingName.count > 80 || isStartingRanking)
                }
            }
            .padding(24)
            .frame(maxWidth: 430)
        }
    }

    private var emptyRoster: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.roundInfo?.needsStart == true {
                Text("Ranking retired")
                    .font(.ostDisplay(20, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("The previous ranking is in History.")
                    .font(.ostBody(13))
                    .foregroundStyle(Theme.textDim)
                Button("Start new ranking") {
                    newRankingName = ""
                    showStartRanking = true
                }
                .buttonStyle(.borderedProminent)
            } else if let name = store.roundInfo?.currentName {
                Text(name)
                    .font(.ostDisplay(20, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Add an OST to begin. It will also appear in History.")
                    .font(.ostBody(13))
                    .foregroundStyle(Theme.textDim)
            } else {
                Text("Loading roster…")
                    .font(.ostBody(13))
                    .foregroundStyle(Theme.textDim)
            }
        }
        .frame(maxWidth: 460, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(24)
    }

    private func close() {
        SoundKit.shared.play(.dismiss)
        selectedOstID = nil
    }

    /// The card wearing the beat-synced treatment right now, if any.
    private var playingOstID: Int? {
        store.playback?.status == .playing ? store.playback?.ostId : nil
    }

    // Filter and search stay at the same place while switching sort modes.
    private var toolbarContent: some View {
        HStack(spacing: 12) {
            Picker("", selection: $submitterFilter) {
                Text("All submitters").tag(Int?.none)
                ForEach(store.people) { person in
                    Text(person.name).tag(Int?.some(person.id))
                }
            }
            .labelsHidden()
            .tint(Theme.accent)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 6))
            .frame(maxWidth: 190)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.textDim)
                TextField("Search title…", text: $search)
                    .textFieldStyle(.plain).font(.ostBody(13))
                    .focused($searchFocused)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 6))
            .frame(maxWidth: searchFocused || !search.isEmpty ? 300 : 200)

            if !store.people.isEmpty {
                Button {
                    fullyRatedOnly.toggle()
                    SoundKit.shared.play(fullyRatedOnly ? .select : .dismiss)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: fullyRatedOnly ? "checkmark.circle.fill" : "circle.dashed")
                            .font(.system(size: 11))
                        Text("Fully rated")
                            .font(.ostMono(11, weight: .medium))
                    }
                    .foregroundStyle(fullyRatedOnly ? Theme.accent : Theme.textDim)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 6))
                .help("Hide OSTs missing any of the \(requiredRatings) ratings")
            }

            if submitterFilter != nil || !search.isEmpty || fullyRatedOnly {
                Text("\(displayedEntries.count) shown")
                    .font(.ostMono(10)).foregroundStyle(Theme.textDim)
                Button("Clear") { submitterFilter = nil; search = ""; fullyRatedOnly = false }
                    .buttonStyle(.plain).font(.ostMono(11, weight: .medium)).foregroundStyle(Theme.accent)
            }
            Spacer()
            if !store.batches.isEmpty || hasSlices {
                Picker("", selection: $sortMode) {
                    Text("Rank").tag(RosterSort.rank)
                    if !store.batches.isEmpty {
                        Text("Batch").tag(RosterSort.batch)
                    }
                    if hasSlices {
                        Text("Slices").tag(RosterSort.slices)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .tint(Theme.accent)
                .frame(width: store.batches.isEmpty || !hasSlices ? 150 : 210)
                .help("Order cards by competition rank, by the private batch key, or by elimination slice")
            }
        }
    }

    private var toolbar: some View {
        // On iPhone the full control row is wider than the screen — wrap it in
        // a horizontal scroll so nothing clips and all controls stay reachable.
        #if os(iOS)
        ScrollView(.horizontal, showsIndicators: false) {
            toolbarContent
                .padding(.horizontal, 20)
        }
        .padding(.top, 12).padding(.bottom, 4)
        #else
        toolbarContent
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 4)
        #endif
    }

    /// One roster cell at its flat position in displayedEntries — shared by the
    /// rank grid and the batch-sectioned grid so the two never drift.
    @ViewBuilder
    private func card(_ entry: RankEntry, index: Int) -> some View {
        let id = entry.ost.id
        RosterCard(
            entry: entry,
            resolutionPhase: store.resolutionPhase[id],
            coverEpoch: store.coverEpoch(for: id),
            isPlaying: playingOstID == id,
            rankDelta: store.rankDeltas[id],
            isKeyboardCursor: gridFocused && cursorIndex == index,
            batchLabel: batchLabel(for: id),
            onPlay: {
                let playing = store.playback?.ostId == id && store.playback?.status == .playing
                SoundKit.shared.play(playing ? .pause : .playStart)
                Task {
                    if playing { await store.pause() }
                    else { await store.play(ostID: id) }
                }
            }
        )
        .id(id)
        .opacity(selectedOstID == id ? 0 : 1)
        .onTapGesture {
            cursorIndex = index   // keep keyboard cursor in sync with mouse
            SoundKit.shared.play(.select)
            selectedOstID = id
        }
    }

    /// Full-width "DAY n · BATCH n" rule between batch groups.
    private func batchSectionHeader(_ title: String) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.ostMono(11, weight: .bold))
                .tracking(2)
                .foregroundStyle(Theme.textDim)
                .fixedSize()
            Rectangle()
                .fill(Theme.textDim.opacity(0.25))
                .frame(height: 1)
        }
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    private func grid(width: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: Theme.gridSpacing) {
                    if sortMode == .slices {
                        // Bottom slice first: each header carries the running
                        // per-person out-tally Python computed for that slice.
                        ForEach(sliceSections, id: \.id) { section in
                            Section {
                                ForEach(section.items, id: \.entry.id) { item in
                                    card(item.entry, index: item.index)
                                }
                            } header: {
                                if let slice = section.slice {
                                    SliceHeader(
                                        slice: slice,
                                        threshold: store.elimination?.threshold ?? 0
                                    )
                                } else {
                                    batchSectionHeader("UNRATED")
                                }
                            }
                        }
                    } else if sortMode == .batch {
                        // Batch view: one full-width header per day, cards below.
                        ForEach(batchSections, id: \.id) { section in
                            Section {
                                ForEach(section.items, id: \.entry.id) { item in
                                    card(item.entry, index: item.index)
                                }
                            } header: {
                                batchSectionHeader(section.title)
                            }
                        }
                    } else {
                        ForEach(Array(displayedEntries.enumerated()), id: \.element.id) { index, entry in
                            card(entry, index: index)
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, bottomClearance)
            }
            .animation(Theme.motion(.reorder, reduceMotion: reduceMotion), value: displayedEntries.map(\.id))
            .onChange(of: store.leaderboard.map(\.id)) { old, new in
                // Whoosh only on genuine re-sorts, not the initial load.
                guard !old.isEmpty, old != new else { return }
                SoundKit.shared.play(.resort)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($gridFocused)
            .onKeyPress(.leftArrow) { moveCursor(dx: -1, dy: 0, width: width, proxy: proxy) }
            .onKeyPress(.rightArrow) { moveCursor(dx: 1, dy: 0, width: width, proxy: proxy) }
            .onKeyPress(.upArrow) { moveCursor(dx: 0, dy: -1, width: width, proxy: proxy) }
            .onKeyPress(.downArrow) { moveCursor(dx: 0, dy: 1, width: width, proxy: proxy) }
            .onKeyPress(.return) { activateCursor() }
            .onKeyPress(.space) { playCursor() }
            .onKeyPress(.escape) {
                guard selectedOstID == nil, cursorIndex != nil else { return .ignored }
                cursorIndex = nil
                return .handled
            }
            .onChange(of: displayedEntries.count) { _, count in
                if let cursor = cursorIndex, cursor >= count {
                    cursorIndex = count > 0 ? count - 1 : nil
                }
            }
        }
    }

    // MARK: Keyboard character-select

    /// Same math LazyVGrid's adaptive layout uses to pick a column count.
    private func columnCount(width: CGFloat) -> Int {
        let available = width - 40   // grid's horizontal padding
        return max(1, Int((available + Theme.gridSpacing) / (180 + Theme.gridSpacing)))
    }

    private func moveCursor(dx: Int, dy: Int, width: CGFloat, proxy: ScrollViewProxy) -> KeyPress.Result {
        guard selectedOstID == nil else { return .ignored }
        let entries = displayedEntries
        guard !entries.isEmpty else { return .ignored }
        let columns = columnCount(width: width)
        guard let current = cursorIndex, current < entries.count else {
            setCursor(0, in: entries, proxy: proxy)
            return .handled
        }
        let target: Int
        if dx != 0 {
            let candidate = current + dx
            // Clamped edges (desktop grid convention) with a distinct bump cue.
            guard candidate >= 0, candidate < entries.count,
                  candidate / columns == current / columns else {
                SoundKit.shared.play(.navBump)
                return .handled
            }
            target = candidate
        } else {
            let candidate = current + dy * columns
            guard candidate >= 0, candidate < entries.count else {
                SoundKit.shared.play(.navBump)
                return .handled
            }
            target = candidate
        }
        setCursor(target, in: entries, proxy: proxy)
        return .handled
    }

    private func setCursor(_ index: Int, in entries: [RankEntry], proxy: ScrollViewProxy) {
        cursorIndex = index
        SoundKit.shared.play(.navMove)
        // ≤100ms per research: fast enough that key-repeat never feels laggy.
        withAnimation(Theme.motion(.feedback, reduceMotion: reduceMotion)) {
            proxy.scrollTo(entries[index].id, anchor: nil)
        }
    }

    private func activateCursor() -> KeyPress.Result {
        guard selectedOstID == nil, let index = cursorIndex,
              index < displayedEntries.count else { return .ignored }
        SoundKit.shared.play(.select)
        selectedOstID = displayedEntries[index].ost.id
        return .handled
    }

    private func playCursor() -> KeyPress.Result {
        guard selectedOstID == nil, let index = cursorIndex,
              index < displayedEntries.count else { return .ignored }
        SoundKit.shared.play(.playStart)
        let id = displayedEntries[index].ost.id
        Task { await store.play(ostID: id) }
        return .handled
    }
}

struct RosterCard: View {
    let entry: RankEntry
    let resolutionPhase: ResolutionPhase?
    let coverEpoch: Int
    /// True while this card's OST is the one playing.
    let isPlaying: Bool
    /// Non-nil right after a re-sort moved this card (positive = climbed).
    let rankDelta: Int?
    /// Keyboard roving cursor is parked here: always-visible focus ring.
    var isKeyboardCursor: Bool = false
    /// "B1·3" batch-key chip, non-nil only while the roster is in Batch sort.
    var batchLabel: String? = nil
    var onPlay: () -> Void = {}

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(Theme.motionKey) private var motionSelection = MotionMode.subtle.rawValue
    private var accent: Color { Theme.accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cover
            info
        }
        .background(Theme.cardSurface, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(
            isKeyboardCursor ? Theme.textPrimary : (isHovered ? Theme.textDim : Theme.separator), lineWidth: 1
        ))
        .overlay {
            // Focus-visible ring, distinct from the hover treatment: the system
            // ring is too faint on this dark theme, so draw our own.
            if isKeyboardCursor {
                RoundedRectangle(cornerRadius: 7).stroke(Theme.textPrimary, lineWidth: 1)
            }
        }
        .overlay {
            if isPlaying {
                RoundedRectangle(cornerRadius: 7).stroke(Theme.accent, lineWidth: 2)
            }
        }
        .overlay(alignment: .topLeading) {
            DiamondBadge(rank: entry.rank)
                .offset(x: 10, y: 10)
        }
        .overlay(alignment: .topTrailing) {
            if let delta = rankDelta {
                RankDeltaChip(delta: delta)
                    .offset(x: -8, y: 8)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let batchLabel {
                Text(batchLabel)
                    .font(.ostMono(10, weight: .bold))
                    .foregroundStyle(Theme.bg)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 4))
                    .offset(x: 10, y: -10)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .onHover { isHovered = $0 }
        .animation(Theme.motion(.feedback, reduceMotion: reduceMotion), value: isHovered)
    }

    private var cover: some View {
        Theme.bgRaised
            .aspectRatio(0.85, contentMode: .fit)
            .overlay {
                CoverImage(path: entry.ost.coverImagePath, epoch: coverEpoch)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .bottomLeading) {
                if let phase = resolutionPhase {
                    ResolutionBadge(phase: phase).padding(6)
                }
            }
            #if os(macOS)
            .overlay(alignment: .bottomTrailing) {
                if isHovered || isPlaying {
                    Button(action: onPlay) {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.bg)
                            .frame(width: 36, height: 36)
                            .background(Theme.accent, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isPlaying ? "Pause \(entry.ost.title)" : "Play \(entry.ost.title)")
                    .padding(10)
                }
            }
            #endif
    }

    private var info: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.ost.title)
                    .font(.ostDisplay(13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(entry.ost.source ?? " ")
                    .font(.ostBody(10))
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
            }
            Spacer()
            Text(entry.average.map { String(format: "%.2f", $0) } ?? "n/a")
                .font(.ostMono(17, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .contentTransition(.numericText(value: entry.average ?? 0))
                .animation(Theme.motion(.feedback, reduceMotion: reduceMotion), value: entry.average)
        }
        .padding(10)
    }
}

/// Playback-resolution status on a card: a clean icon + short label instead of
/// the raw pipeline phase string.
struct ResolutionBadge: View {
    let phase: ResolutionPhase

    private var label: String {
        switch phase {
        case .externalLink, .extracting: "Resolving"
        case .searchingYouTube: "YouTube"
        case .searchingSpotifyMeta: "Spotify"
        case .searchingBing: "Bing"
        case .ready: "Ready"
        case .failed: "Unavailable"
        }
    }

    private var icon: String {
        switch phase {
        case .ready: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        default: "waveform"
        }
    }

    private var tint: Color {
        switch phase {
        case .ready: Theme.accent
        case .failed: Theme.rust
        default: Theme.accent
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold))
            Text(label).font(.ostMono(9, weight: .medium))
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(ChamferedRect(cut: 4).fill(Theme.bg.opacity(0.85)))
        .foregroundStyle(tint)
    }
}

/// Cover art straight off disk (the Python side caches covers as files and
/// hands us paths). Accent-colored placeholder when missing.
struct CoverImage: View {
    let path: String?
    // Cover files are rewritten in place server-side, so the path alone can't
    // signal a change. A bumped epoch alters this view's stored state, which
    // makes SwiftUI re-run body and NSImage re-read the file from disk.
    // Deliberately REQUIRED (no default): a call site that forgot to pass it
    // would silently reintroduce the stale-cover bug.
    let epoch: Int

    var body: some View {
        if let path, let image = Self.cachedCover(path: path, epoch: epoch) {
            #if os(macOS)
            Image(nsImage: image).resizable()
            #else
            Image(uiImage: image).resizable()
            #endif
        } else {
            ZStack {
                Theme.bgRaised
                Image(systemName: "music.note")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.textDim)
            }
        }
    }
}

/// The "news chip": rank movement after a re-sort. Climbs are accent green,
/// falls are rust; the store sweeps deltas away after ~4s so this self-dismisses.
private struct RankDeltaChip: View {
    let delta: Int

    var body: some View {
        Text("\(delta > 0 ? "▲" : "▼")\(abs(delta))")
            .font(.ostMono(10, weight: .bold))
            .foregroundStyle(.black)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(
                ChamferedRect(cut: 5).fill(delta > 0 ? Theme.accent : Theme.rust)
            )
            .accessibilityLabel(delta > 0 ? "climbed \(abs(delta))" : "fell \(abs(delta))")
    }
}

extension CoverImage {
    #if os(macOS)
    /// Decoded covers keyed by path#epoch. NSImage(contentsOfFile:) is a
    /// synchronous main-thread disk read + decode — uncached it re-ran on
    /// structural re-renders and stuttered the initial reveal.
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 150
        return cache
    }()

    static func cachedCover(path: String, epoch: Int) -> NSImage? {
        let key = "\(path)#\(epoch)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = decodeAtDisplaySize(path) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    /// Downsample-on-decode via ImageIO instead of NSImage(contentsOfFile:),
    /// which fully decodes the stored 600px JPEG every time it misses the
    /// cache. Thumbnail decode reads only what's needed for the render size —
    /// noticeably cheaper on slow disks and old CPUs.
    private static func decodeAtDisplaySize(_ path: String) -> NSImage? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 600,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
    #else
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 150
        return cache
    }()

    static func cachedCover(path: String, epoch: Int) -> UIImage? {
        let key = "\(path)#\(epoch)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = decodeAtDisplaySize(path) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    private static func decodeAtDisplaySize(_ path: String) -> UIImage? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 600,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
    #endif
}
