// Detail view for one OST: big cover, stats from Python, playback
// controls, and the full 0–10 rating strip per person. Every number that
// appears here was computed server-side.

import SwiftUI
#if os(iOS)
import UIKit
#endif

struct DetailView: View {
    let store: AppStore
    let ostID: Int
    var onClose: () -> Void = {}

    @State private var showCoverPicker = false
    @State private var confirmingDelete = false
    @State private var playInFlight = false
    #if os(iOS)
    @State private var keyboardVisible = false
    #endif
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

    private var isThisTrackActive: Bool {
        store.playback?.ostId == ostID
            && (store.playback?.status == .playing || store.playback?.status == .paused)
    }

    var body: some View {
        if let entry = entry ?? lastEntry {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    #if os(macOS)
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
                    #endif
                    hero(entry)
                    stats(entry)
                    ratingGrid(entry)
                }
                #if os(iOS)
                .padding(18)
                #else
                .padding(24)
                #endif
            }
            #if os(iOS)
            .safeAreaInset(edge: .top, spacing: 0) {
                detailActions
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if (playInFlight || isThisTrackActive) && !keyboardVisible {
                    detailProgress
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(Theme.bgRaised)
                        .overlay(alignment: .top) { Theme.separator.frame(height: 1) }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                setKeyboardVisible(true)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
                setKeyboardVisible(false)
            }
            #endif
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
                Text("Its ratings will also be deleted. This can't be undone.")
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

    #if os(iOS)
    private var detailActions: some View {
        HStack {
            Menu {
                Button("Delete OST", systemImage: "trash", role: .destructive) {
                    confirmingDelete = true
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textDim)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("OST actions")
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close OST details")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 4)
        .background(Theme.bgRaised)
        .overlay(alignment: .bottom) { Theme.separator.frame(height: 1) }
    }
    #endif

    @ViewBuilder private func hero(_ entry: RankEntry) -> some View {
        #if os(iOS)
        HStack(alignment: .top, spacing: 16) {
            heroCover(entry)
                .aspectRatio(1, contentMode: .fit)
                .frame(width: 112, height: 112)
            heroMeta(entry)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        #else
        HStack(alignment: .top, spacing: 20) {
            heroCover(entry).frame(width: 220, height: 220)
            heroMeta(entry)
            Spacer(minLength: 0)
        }
        #endif
    }

    private func heroCover(_ entry: RankEntry) -> some View {
        CoverImage(path: entry.ost.coverImagePath, epoch: store.coverEpoch(for: entry.ost.id))
            .scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(alignment: .bottomTrailing) {
                Button { showCoverPicker = true } label: {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .padding(8)
                }
                .buttonStyle(.plain)
                .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 6))
                .padding(8)
                .help("Change cover art")
            }
    }

    private func heroMeta(_ entry: RankEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let rank = entry.rank {
                Text("#\(rank)")
                    .font(.ostMono(11, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Theme.cardSurface, in: Capsule())
            }
            Text(entry.ost.title)
                .font(.ostDisplay(19, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let source = entry.ost.source {
                Text(source).font(.ostBody(14)).foregroundStyle(Theme.textDim)
            }
            if let submitter = entry.ost.submitterName {
                Text("submitted by \(submitter)")
                    .font(.ostBody(12)).foregroundStyle(Theme.textDim)
            }
            playButton(entry)
        }
    }

    private func playButton(_ entry: RankEntry) -> some View {
        HStack(spacing: 10) {
            Button {
                if isThisPlaying {
                    SoundKit.shared.play(.pause)
                    Task { await store.pause() }
                } else {
                    SoundKit.shared.play(.playStart)
                    playInFlight = true
                    Task {
                        await store.play(ostID: entry.ost.id)
                        playInFlight = false
                    }
                }
            } label: {
                Label(playInFlight ? "Loading…" : (isThisPlaying ? "Pause" : (isThisTrackActive ? "Resume" : "Play")),
                      systemImage: playInFlight ? "ellipsis" : (isThisPlaying ? "pause.fill" : "play.fill"))
                    .font(.ostDisplay(13, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 3)
            }
            .buttonStyle(.borderedProminent)
            .disabled(playInFlight)

            if let phase = store.resolutionPhase[entry.ost.id] {
                Text(phase.rawValue)
                    .font(.ostMono(11))
                    .foregroundStyle(phase == .failed ? Theme.rust : Theme.textDim)
                    .contentTransition(.opacity)
            }
        }
    }

    #if os(iOS)
    private var detailProgress: some View {
        let duration = isThisTrackActive ? store.player.duration : 0
        let position = isThisTrackActive ? store.player.position : 0
        let fraction = duration > 0 ? min(max(position / duration, 0), 1) : 0
        return VStack(spacing: 6) {
            HStack {
                Text(playInFlight ? "Finding audio…" : (isThisPlaying ? "Now playing" : "Paused"))
                Spacer()
                Text("\(formatTime(position)) / \(formatTime(duration))")
                    .monospacedDigit()
                if isThisTrackActive {
                    Button {
                        Task {
                            if isThisPlaying { await store.pause() }
                            else { await store.play(ostID: ostID) }
                        }
                    } label: {
                        Image(systemName: isThisPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 34, height: 30)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isThisPlaying ? "Pause" : "Resume")
                }
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.textDim.opacity(0.25))
                    Capsule().fill(Theme.accent)
                        .frame(width: geometry.size.width * fraction)
                }
            }
            .frame(height: 3)
            .font(.ostMono(10))
            .foregroundStyle(Theme.textDim)
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    private func setKeyboardVisible(_ visible: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { keyboardVisible = visible }
    }
    #endif

    // Stat tiles share the same glass treatment as the rating boxes below so
    // every raised surface on the detail panel reads as one material.
    private func stats(_ entry: RankEntry) -> some View {
        HStack(spacing: 4) {
            compactStat("AVG", entry.average.map { String(format: "%.2f", $0) } ?? "—", Theme.accent)
            compactStat("MIN", entry.minimum.map(\.scoreLabel) ?? "—", Theme.textPrimary)
            compactStat("MAX", entry.maximum.map(\.scoreLabel) ?? "—", Theme.textPrimary)
            compactStat("σ", entry.stddev.map { String(format: "%.2f", $0) } ?? "—", Theme.textPrimary)
            compactStat("VOTES", "\(entry.ratingCount)", Theme.textPrimary)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Theme.separator.frame(height: 1) }
        .overlay(alignment: .bottom) { Theme.separator.frame(height: 1) }
    }

    private func compactStat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.ostMono(15, weight: .bold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(label)
                .font(.ostMono(9))
                .foregroundStyle(Theme.textDim)
        }
        .frame(maxWidth: .infinity)
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
        Theme.accent
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
            TextField("Score", text: $text)
                .textFieldStyle(.plain)
                .font(.ostMono(20, weight: .bold))
                .multilineTextAlignment(.center)
                // Always bright: accent when a score is set, primary otherwise —
                // never dependent on a tinted background rendering underneath.
                .foregroundStyle(score == nil || isFocused ? Theme.textPrimary : accent)
                .frame(width: 70, height: 38)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(isFocused ? 0.10 : 0.05)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(
                    isFocused ? accent : (score == nil ? Color.white.opacity(0.14) : accent.opacity(0.55)),
                    lineWidth: 1))
                .focused($isFocused)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
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
