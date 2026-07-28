// Hero-zoom destination for one OST: big cover, stats from Python, playback
// controls, and the full 0–10 rating strip per person. Every number that
// appears here was computed server-side.

import SwiftUI

struct DetailView: View {
    let store: AppStore
    let ostID: Int
    var onClose: () -> Void = {}

    @State private var showCoverPicker = false
    @State private var confirmingDelete = false
    /// Per-person burst counters: bumping one fires that row's ParticleBurst.
    @State private var celebrations: [Int: Int] = [:]
    /// Last successfully resolved entry. The live lookup can go nil mid-close
    /// (a resync or /ws leaderboardResorted push landing while the panel is
    /// still dismissing) — fall back to this instead of flashing "not found".
    @State private var lastEntry: RankEntry?

    private var entry: RankEntry? {
        store.leaderboard.first { $0.ost.id == ostID }
    }

    private var isThisPlaying: Bool {
        store.playback?.ostId == ostID && store.playback?.status == .playing
    }

    var body: some View {
        if let entry = entry ?? lastEntry {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        Button { confirmingDelete = true } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.textDim)
                        }
                        .buttonStyle(.plain)
                        .help("Delete this OST")
                        Spacer()
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Theme.textDim)
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.escape, modifiers: [])
                    }
                    hero(entry)
                    stats(entry)
                    ratingGrid(entry)
                }
                .padding(24)
            }
            .sheet(isPresented: $showCoverPicker) {
                CoverPickerView(store: store, ostID: ostID, accent: accent(entry))
            }
            .confirmationDialog(
                "Delete \u{201C}\(entry.ost.title)\u{201D}?",
                isPresented: $confirmingDelete
            ) {
                Button("Delete OST", role: .destructive) {
                    Task {
                        if await store.deleteOst(id: ostID) { onClose() }
                    }
                }
            } message: {
                Text("All of its ratings go with it. This can't be undone.")
            }
            // `self.` is required: `entry` is shadowed above by the
            // unwrapped local, but the live optional lookup is what must be
            // observed to catch it going nil mid-close-animation.
            .onChange(of: self.entry, initial: true) { _, newValue in
                if let newValue { lastEntry = newValue }
            }
        } else {
            ContentUnavailableView("OST not found", systemImage: "questionmark.square.dashed")
        }
    }

    private func hero(_ entry: RankEntry) -> some View {
        HStack(alignment: .top, spacing: 20) {
            CoverImage(path: entry.ost.coverImagePath, epoch: store.coverEpoch(for: entry.ost.id))
                .aspectRatio(1, contentMode: .fill)
                .frame(width: 220, height: 220)
                .clipShape(ChamferedRect())
                .overlay(ChamferedRect().stroke(accent(entry).opacity(0.6), lineWidth: 1.5))
                .overlay(alignment: .bottomTrailing) {
                    Button { showCoverPicker = true } label: {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .padding(8)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(accent(entry).opacity(0.3)).interactive(), in: .circle)
                    .padding(8)
                    .help("Change cover art")
                }
                // Bass thump while THIS ost is the one playing.
                .musicPulse(
                    spectrum: store.player.spectrum, isPlaying: isThisPlaying,
                    amount: Theme.coverThump
                )

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    DiamondBadge(rank: entry.rank, size: 44)
                    Text(entry.ost.title)
                        .font(.ostDisplay(26, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                }
                if let source = entry.ost.source {
                    Text(source).font(.ostBody(14)).foregroundStyle(Theme.textDim)
                }
                if let submitter = entry.ost.submitterName {
                    Text("submitted by \(submitter)")
                        .font(.ostBody(12)).foregroundStyle(accent(entry))
                }
                Spacer(minLength: 8)
                playButton(entry)
            }
        }
    }

    private func playButton(_ entry: RankEntry) -> some View {
        HStack(spacing: 10) {
            Button {
                SoundKit.shared.play(.playStart)
                Task { await store.play(ostID: entry.ost.id) }
            } label: {
                Label("Play", systemImage: "play.fill")
                    .font(.ostDisplay(13, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 3)
            }
            .buttonStyle(.glass)
            .tint(accent(entry))

            if let phase = store.resolutionPhase[entry.ost.id] {
                Text(phase.rawValue)
                    .font(.ostMono(11))
                    .foregroundStyle(phase == .failed ? Theme.rust : Theme.textDim)
                    .contentTransition(.opacity)
            }
        }
    }

    // Stat tiles share the same glass treatment as the rating boxes below so
    // every raised surface on the detail panel reads as one material.
    private func stats(_ entry: RankEntry) -> some View {
        HStack(spacing: 14) {
            stat("AVG", entry.average.map { String(format: "%.2f", $0) } ?? "—", accent(entry))
            stat("MIN", entry.minimum.map(\.scoreLabel) ?? "—", Theme.textDim)
            stat("MAX", entry.maximum.map(\.scoreLabel) ?? "—", Theme.textDim)
            stat("σ", entry.stddev.map { String(format: "%.2f", $0) } ?? "—", Theme.textDim)
            stat("VOTES", "\(entry.ratingCount)", Theme.textDim)
        }
    }

    private func stat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.ostMono(20, weight: .bold)).foregroundStyle(color)
            Text(label).font(.ostDisplay(10)).foregroundStyle(Theme.textDim)
        }
        .frame(minWidth: 72)
        .padding(.vertical, 10)
        // Faint dark tint guarantees tile boundaries stay visible even where the
        // panel's glass stack bottoms out on the near-black backdrop.
        .glassEffect(.regular.tint(Color.black.opacity(0.25)), in: ChamferedRect(cut: 10))
    }

    private func ratingGrid(_ entry: RankEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("RATINGS")
                .font(.ostDisplay(13, weight: .semibold))
                .foregroundStyle(Theme.accent)
            ForEach(store.people) { person in
                RatingRow(
                    person: person,
                    score: store.scores[entry.ost.id]?[person.id],
                    isSubmitter: person.id == entry.ost.submitterId,
                    accent: accent(entry),
                    celebrationTrigger: celebrations[person.id] ?? 0
                ) { newScore in
                    SoundKit.shared.play(rating: newScore)
                    if newScore == 10 {
                        celebrations[person.id, default: 0] += 1
                    }
                    Task { await store.rate(ostID: entry.ost.id, raterID: person.id, score: newScore) }
                }
            }
        }
    }

    private func accent(_ entry: RankEntry) -> Color {
        entry.ost.coverAccentHex.map { Color(hex: $0) } ?? Theme.pink
    }
}

/// One rater: their name and a free-form box to type their 0–10 score — any
/// decimal (6.7, 8.66). Commit on Return or focus loss; empty the box to clear.
struct RatingRow: View {
    let person: Person
    let score: Double?
    let isSubmitter: Bool
    let accent: Color
    var celebrationTrigger: Int = 0
    let onSet: (Double?) -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Discreet rater identity: deterministic per-person color dot.
            Circle()
                .fill(Theme.personAccent(person.id))
                .frame(width: 6, height: 6)
            Text(person.name)
                .font(.ostBody(16))
                .foregroundStyle(Theme.textPrimary)
            if isSubmitter {
                Text("self")
                    .font(.ostMono(9))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(ChamferedRect(cut: 4).fill(Theme.accent.opacity(0.2)))
                    .foregroundStyle(Theme.accent)
            }
            Spacer()
            TextField("—", text: $text)
                .textFieldStyle(.plain)
                .font(.ostMono(20, weight: .bold))
                .multilineTextAlignment(.center)
                // Always bright: accent when a score is set, primary otherwise —
                // never dependent on a tinted background rendering underneath.
                .foregroundStyle(score == nil || isFocused ? Theme.textPrimary : accent)
                .frame(width: 76, height: 44)
                .background(ChamferedRect(cut: 8).fill(Color.white.opacity(isFocused ? 0.10 : 0.05)))
                .overlay(ChamferedRect(cut: 8).strokeBorder(
                    isFocused ? accent : (score == nil ? Color.white.opacity(0.14) : accent.opacity(0.55)),
                    lineWidth: 1))
                .focused($isFocused)
                .onSubmit { commit() }
                .onAppear { text = score.map(\.scoreLabel) ?? "" }
                .onChange(of: score) { _, newValue in
                    if !isFocused { text = newValue.map(\.scoreLabel) ?? "" }
                }
                .onChange(of: isFocused) { _, focused in
                    if !focused { commit() }
                }
        }
        .padding(.vertical, 7)
        // Perfect-10 burst erupts over the row without blocking any input.
        .overlay { ParticleBurst(trigger: celebrationTrigger, accent: accent) }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            if score != nil { onSet(nil) }
            return
        }
        guard let value = Double(trimmed.replacingOccurrences(of: ",", with: ".")) else {
            text = score.map(\.scoreLabel) ?? ""  // junk input: revert
            return
        }
        let clamped = (min(10, max(0, value)) * 100).rounded() / 100
        text = clamped.scoreLabel
        if clamped != score { onSet(clamped) }
    }
}
