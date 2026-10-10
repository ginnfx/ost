// Fullscreen cassette visualizer with optional synced lyrics.

import SwiftUI

struct VisualizerView: View {
    let store: AppStore
    var onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(Theme.motionKey) private var motionSelection = MotionMode.subtle.rawValue
    @AppStorage(Theme.fxDefaultsKey) private var fxEnabled = true
    @AppStorage(Theme.fxIntensityKey) private var fxIntensity = 1.0
    @State private var spin = ReelSpin()
    @State private var lyrics: [LyricLine]?
    @State private var lyricsOstID: Int?   // which track the current lines belong to

    private var entry: RankEntry? { store.nowPlayingEntry }
    private var isPlaying: Bool { store.playback?.status == .playing }
    private var stillArtwork: Bool {
        reduceMotion || !fxEnabled || motionSelection == MotionMode.minimal.rawValue
    }
    private var accent: Color {
        entry?.ost.coverAccentHex.map { Color(hex: $0) } ?? Theme.accent
    }

    var body: some View {
        GeometryReader { geo in
            // One uniform factor (designed at 1280x800) drives every size in
            // both layouts — ring, type, column, padding — so the takeover
            // scales as a whole between windowed and fullscreen instead of
            // fixed-size elements floating in more or less empty space.
            let scale = max(0.55, min(1.6, min(geo.size.width / 1280, geo.size.height / 800)))
            ZStack {
            backdrop
                .contentShape(Rectangle())
                .onTapGesture { onClose() }   // empty space closes; lyrics keep their taps

            if let lines = lyrics, !lines.isEmpty {
                lyricsLayout(lines, scale: scale)
            } else {
                centeredLayout(scale: scale)
            }

            closeButton

            // Invisible key handlers: Esc leaves, Space toggles transport.
            Button("", action: onClose)
                .keyboardShortcut(.escape, modifiers: [])
                .hidden()
            Button("") {
                SoundKit.shared.play(isPlaying ? .pause : .playStart)
                Task {
                    if isPlaying {
                        await store.pause()
                    } else if let id = store.playback?.ostId {
                        await store.play(ostID: id)
                    }
                }
            }
            .keyboardShortcut(.space, modifiers: [])
            .hidden()
            }
        }
        // The id folds in duration availability: opening the visualizer before
        // AVPlayer reports a duration fetches a provisional (uncached) guess,
        // and when the real duration lands moments later this task re-runs and
        // replaces it with a duration-validated match.
        .task(id: "\(entry?.ost.id ?? -1)|\(store.player.duration > 1)") {
            guard let ost = entry?.ost else {
                lyrics = nil
                lyricsOstID = nil
                return
            }
            // New track: drop the old lines. Same track re-validating (the
            // duration just landed): keep the provisional lines on screen
            // until the validated result replaces them.
            if lyricsOstID != ost.id {
                lyrics = nil
                lyricsOstID = ost.id
            }
            let duration = store.player.duration > 1 ? store.player.duration : nil
            lyrics = await LyricsService.shared.lyrics(for: ost, duration: duration)
        }
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel("Fullscreen visualizer. Press Escape to close.")
    }

    // MARK: Layouts

    private func centeredLayout(scale: CGFloat) -> some View {
        VStack(spacing: 28 * scale) {
            Spacer(minLength: 20)
            PocketDeck(
                store: store, accent: accent, spin: spin,
                isPlaying: isPlaying, still: stillArtwork, intensity: fxIntensity
            )
            .frame(width: 470 * scale, height: 320 * scale)
            titleBlock(compact: false, scale: scale)
            Spacer(minLength: 20)
        }
        .padding(40 * scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)   // taps fall through to the closing backdrop
    }

    private func lyricsLayout(_ lines: [LyricLine], scale: CGFloat) -> some View {
        HStack(spacing: 48 * scale) {
            VStack(alignment: .leading, spacing: 6 * scale) {
                titleBlock(compact: true, scale: scale)
                SyncedLyricsView(
                    lines: lines,
                    player: store.player,
                    isPlaying: isPlaying,
                    accent: accent,
                    scale: scale
                ) { time in
                    Task { await store.seek(to: time) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 20 * scale) {
                PocketDeck(
                    store: store, accent: accent, spin: spin,
                    isPlaying: isPlaying, still: stillArtwork, intensity: fxIntensity
                )
                .frame(width: 330 * scale, height: 225 * scale)
                if let average = entry?.average {
                    Text(String(format: "%.2f", average))
                        .font(.ostMono(16 * scale, weight: .bold))
                        .foregroundStyle(accent)
                }
            }
            .frame(width: 380 * scale)
            .allowsHitTesting(false)
        }
        .padding(.horizontal, 60 * scale)
        .padding(.vertical, 40 * scale)
    }

    private var closeButton: some View {
        VStack {
            HStack {
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.textDim)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 6))
            }
            Spacer()
        }
        .padding(24)
    }

    /// A quiet backdrop keeps the artwork and playback controls legible.
    private var backdrop: some View {
        Theme.bg.ignoresSafeArea()
    }

    private func titleBlock(compact: Bool, scale: CGFloat) -> some View {
        VStack(alignment: compact ? .leading : .center, spacing: 8 * scale) {
            HStack(spacing: 14 * scale) {
                if let rank = entry?.rank {
                    DiamondBadge(rank: rank, size: (compact ? 28 : 36) * scale)
                }
                Text(entry?.ost.title ?? "Nothing playing")
                    .font(.ostDisplay((compact ? 24 : 34) * scale, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(compact ? .leading : .center)
            }
            if let source = entry?.ost.source {
                Text(source)
                    .font(.ostBody((compact ? 13 : 16) * scale))
                    .foregroundStyle(Theme.textDim)
            }
            if !compact, let average = entry?.average {
                Text(String(format: "%.2f", average))
                    .font(.ostMono(18 * scale, weight: .bold))
                    .foregroundStyle(accent)
            }
        }
    }
}
