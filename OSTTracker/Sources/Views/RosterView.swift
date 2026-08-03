// The character-select roster: 50 chamfered cards, diamond rank badges,
// mono scores, hover glow, staggered reveal, live re-sort. Cards stay SOLID
// content surfaces; glass is reserved for chrome and the detail overlay panel
// (see RootView header for the glass policy). Card -> detail is a hero zoom
// done with matchedGeometryEffect (navigationTransition(.zoom) is iOS-only).

#if os(macOS)
import GlowEffectKit
#endif
import SwiftUI

struct RosterView: View {
    let store: AppStore
    // Owned by RootView so the Add-OST sheet can read the active filter.
    @Binding var submitterFilter: Int?
    @State private var selectedOstID: Int?
    @State private var search = ""
    @Namespace private var hero
    // Shared sampling namespace for the toolbar's grouped glass (filter + search)
    // so they morph together — and expand — instead of reading as disconnected chips.
    @Namespace private var toolbarGlass
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

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 230), spacing: Theme.gridSpacing)]
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
            // Detail panel sizing: render 1:1 in normal windows, then grow
            // PROPORTIONALLY (content and all) on big/fullscreen windows.
            // Without the cap the panel stretches to fill the screen while its
            // fixed-size content huddles top-left.
            let detailScale = min(1.3, max(1.0, min(geo.size.width / 1150, geo.size.height / 900)))
            ZStack {
            VStack(spacing: 0) {
                toolbar
                if sortMode == .slices, let board = store.elimination {
                    HStack(alignment: .top, spacing: 14) {
                        // The grid keeps the sidebar's width out of its column math.
                        grid(width: geo.size.width - Self.sidebarWidth - 34)
                        EliminationSidebar(board: board)
                            .padding(.top, 20)
                            .padding(.trailing, 20)
                            .padding(.bottom, 90)   // clear the now-playing bar
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

                // GlassEffectContainer gives the panel's glass and the glass
                // elements INSIDE DetailView (stat tiles, rating boxes) one
                // shared sampling region — stacked glass without it renders
                // invisible (same rule as the header chrome).
                GlassEffectContainer {
                    DetailView(store: store, ostID: id, onClose: close)
                        // Glass panel floating over the dimmed roster. The dark tint
                        // keeps text/stat contrast while the material still samples
                        // the grid behind it — consistent with the rest of the chrome.
                        .glassEffect(.regular.tint(Color.black.opacity(0.55)), in: ChamferedRect())
                        .overlay(ChamferedRect().stroke(Theme.accent.opacity(0.35), lineWidth: 1.5))
                        .clipShape(ChamferedRect())
                }
                .frame(maxWidth: 920, maxHeight: 800)
                .matchedGeometryEffect(id: "hero-\(id)", in: hero)
                .scaleEffect(detailScale)
                .padding(40)
                .zIndex(1)
            }
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.82), value: selectedOstID)
            .onChange(of: hasSlices) { _, has in
                // Never strand the picker on an option it no longer offers (e.g.
                // the last rating was cleared away).
                if !has, sortMode == .slices { sortMode = .rank }
            }
        }
    }

    private func close() {
        SoundKit.shared.play(.dismiss)
        selectedOstID = nil
    }

    /// The card wearing the beat-synced treatment right now, if any.
    private var playingOstID: Int? {
        store.playback?.status == .playing ? store.playback?.ostId : nil
    }

    // Submitter filter + title search are grouped in one GlassEffectContainer
    // sharing `toolbarGlass`, each tagged with a glassEffectID. Because they sit
    // in a shared sampling region, the search field's width change (on focus /
    // non-empty query) MORPHS the two glass shapes together rather than snapping
    // between disconnected chips. Animate `searchFocused` to see the morph.
    private var toolbar: some View {
        GlassEffectContainer(spacing: 12) {
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
                .glassEffect(.regular, in: ChamferedRect(cut: 8))
                .glassEffectID("filter", in: toolbarGlass)
                .frame(maxWidth: 190)

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.textDim)
                    TextField("Search title…", text: $search)
                        .textFieldStyle(.plain).font(.ostBody(13))
                        .focused($searchFocused)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .glassEffect(.regular, in: ChamferedRect(cut: 8))
                .glassEffectID("search", in: toolbarGlass)
                .frame(maxWidth: searchFocused || !search.isEmpty ? 300 : 200)

                // Completeness filter. Only meaningful once there are raters to
                // be missing, so it stays out of the chrome until then.
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
                    .glassEffect(.regular, in: ChamferedRect(cut: 8))
                    .glassEffectID("complete", in: toolbarGlass)
                    .help("Hide OSTs missing any of the \(requiredRatings) ratings")
                }

                if submitterFilter != nil || !search.isEmpty || fullyRatedOnly {
                    Text("\(displayedEntries.count) shown")
                        .font(.ostMono(10)).foregroundStyle(Theme.textDim)
                    Button("Clear") { submitterFilter = nil; search = ""; fullyRatedOnly = false }
                        .buttonStyle(.plain).font(.ostMono(11, weight: .medium)).foregroundStyle(Theme.accent)
                }
                Spacer()
                // Batch sort is a host-only view of the private key (only once
                // batches exist); slices need a ranked board to cut up.
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
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: searchFocused)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: search.isEmpty)
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 4)
    }

    /// One roster cell at its flat position in displayedEntries — shared by the
    /// rank grid and the batch-sectioned grid so the two never drift.
    @ViewBuilder
    private func card(_ entry: RankEntry, index: Int) -> some View {
        let id = entry.ost.id
        RosterCard(
            entry: entry,
            resolutionPhase: store.resolutionPhase[id],
            revealIndex: store.hasRevealed ? nil : index,
            coverEpoch: store.coverEpoch(for: id),
            isPlaying: playingOstID == id,
            spectrum: store.player.spectrum,
            rankDelta: store.rankDeltas[id],
            isKeyboardCursor: gridFocused && cursorIndex == index,
            batchLabel: batchLabel(for: id)
        )
        .id(id)
        .matchedGeometryEffect(
            id: "hero-\(id)", in: hero, isSource: selectedOstID != id
        )
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
                .padding(.bottom, 90)   // clear the now-playing bar
            }
            .animation(Theme.resortAnimation, value: displayedEntries.map(\.id))
            .onChange(of: store.leaderboard.map(\.id)) { old, new in
                // Whoosh only on genuine re-sorts, not the initial load.
                guard !old.isEmpty, old != new else { return }
                SoundKit.shared.play(.resort)
            }
            .task {
                try? await Task.sleep(for: .seconds(
                    Double(store.leaderboard.count) * Theme.revealStagger + 0.6
                ))
                store.markRevealed()
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
        withAnimation(.easeOut(duration: 0.1)) {
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
    /// Non-nil during the first-load reveal sequence: drives the stagger.
    let revealIndex: Int?
    let coverEpoch: Int
    /// True while this card's OST is the one playing: beat glow + bass pulse.
    let isPlaying: Bool
    let spectrum: SpectrumEngine
    /// Non-nil right after a re-sort moved this card (positive = climbed).
    let rankDelta: Int?
    /// Keyboard roving cursor is parked here: always-visible focus ring.
    var isKeyboardCursor: Bool = false
    /// "B1·3" batch-key chip, non-nil only while the roster is in Batch sort.
    var batchLabel: String? = nil

    @State private var isHovered = false
    @State private var revealed = false
    @AppStorage(Theme.fxDefaultsKey) private var fxEnabled = true

    private var accent: Color {
        entry.ost.coverAccentHex.map { Color(hex: $0) } ?? Theme.pink
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cover
            info
        }
        .background(ChamferedRect().fill(Theme.cardSurface))
        .overlay(ChamferedRect().stroke(
            accent.opacity(isHovered || isKeyboardCursor ? 0.9 : 0.35), lineWidth: 1.5
        ))
        .overlay {
            // Focus-visible ring, distinct from the hover treatment: the system
            // ring is too faint on this dark theme, so draw our own.
            if isKeyboardCursor {
                ChamferedRect().stroke(Color.white.opacity(0.85), lineWidth: 2)
            }
        }
        .overlay {
            if isPlaying, fxEnabled {
                BeatStroke(spectrum: spectrum, accent: accent)
            } else if isPlaying {
                // FX off: still mark the playing card, just statically.
                ChamferedRect().stroke(accent.opacity(0.8), lineWidth: 2)
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
                    .background(ChamferedRect(cut: 5).fill(Theme.accent))
                    .offset(x: 10, y: -10)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: rankDelta)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: batchLabel)
        .clipShape(ChamferedRect())
        .compositingGroup()
        .modifier(HoverGlow(isActive: isHovered || isKeyboardCursor, accent: accent))
        .scaleEffect(isHovered || isKeyboardCursor ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .animation(.easeOut(duration: 0.1), value: isKeyboardCursor)
        .musicPulse(onlyWhen: isPlaying, spectrum: spectrum, amount: Theme.beatPulse)
        .onHover { hovering in
            if hovering, !isHovered { SoundKit.shared.play(.hoverTick) }
            isHovered = hovering
        }
        .opacity(revealed ? 1 : 0)
        .offset(y: revealed ? 0 : 24)
        .onAppear {
            guard let index = revealIndex else {
                revealed = true
                return
            }
            withAnimation(
                .spring(response: 0.5, dampingFraction: 0.8)
                    .delay(Double(index) * Theme.revealStagger)
            ) {
                revealed = true
            }
        }
    }

    private var cover: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay { CoverImage(path: entry.ost.coverImagePath, epoch: coverEpoch).scaledToFill() }
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if let phase = resolutionPhase {
                    ResolutionBadge(phase: phase).padding(6)
                }
            }
            .overlay(
                LinearGradient(
                    colors: [.clear, accent.opacity(0.28)],
                    startPoint: .center, endPoint: .bottom
                )
            )
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
            Text(entry.average.map { String(format: "%.2f", $0) } ?? "—")
                .font(.ostMono(17, weight: .bold))
                .foregroundStyle(accent)
                .contentTransition(.numericText(value: entry.average ?? 0))
                .animation(.easeOut(duration: 0.6), value: entry.average)
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
            Image(nsImage: image).resizable()
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

/// Bass-driven accent stroke worn by the currently-playing card. A TimelineView
/// leaf — only this stroke re-renders per frame, never the card body.
private struct BeatStroke: View {
    let spectrum: SpectrumEngine
    let accent: Color

    @State private var pulse = AudioPulse()
    // HIG: Reduce Motion disables ambient/looping animation entirely — matches
    // the guard every sibling TimelineView (SpectrumView, VinylArtwork, etc.) uses.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { _ in
            let env = reduceMotion ? AudioEnvelopes() : pulse.update(bands: spectrum.snapshot())
            ChamferedRect()
                .stroke(accent.opacity(0.35 + 0.6 * env.bass), lineWidth: 1.5 + 2.0 * env.bass)
        }
        .allowsHitTesting(false)
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

/// GlowEffectKit's modifier costs real per-update time even while INACTIVE —
/// with 50 cards it showed up in idle Instruments samples. Attach it only
/// while a card is actually glowing.
private struct HoverGlow: ViewModifier {
    let isActive: Bool
    let accent: Color

    func body(content: Content) -> some View {
        if isActive {
            content.glowEffect(
                isActive: true,
                shape: ChamferedRect(),
                duration: Theme.hoverGlowDuration,
                glowColors: [accent, Theme.accent],
                lineWidth: 3
            )
        } else {
            content
        }
    }
}

extension CoverImage {
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
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
