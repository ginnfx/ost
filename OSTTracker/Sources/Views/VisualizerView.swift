// Party mode: fullscreen takeover for when a track is just PLAYING. Blurred
// cover ambience (dynamic color on decoration, fixed high-contrast text over a
// dark scrim), a radial spectrum ring around spinning cover art, and — when
// LRCLIB has synced lyrics for the track — a Spotify-style lyric panel with
// the ring docked to the side. Esc or the close button leaves; clicking empty
// backdrop leaves; Space toggles play/pause. Reduce Motion: no spin, no drift.

import SwiftUI

struct VisualizerView: View {
    let store: AppStore
    var onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = VinylSpin()
    @State private var lyrics: [LyricLine]?
    @State private var lyricsOstID: Int?   // which track the current lines belong to

    private var entry: RankEntry? { store.nowPlayingEntry }
    private var isPlaying: Bool { store.playback?.status == .playing }
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
            SpectrumRing(
                store: store, accent: accent, diameter: 470 * scale,
                spin: spin, isPlaying: isPlaying, reduceMotion: reduceMotion
            )
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
                SpectrumRing(
                    store: store, accent: accent, diameter: 330 * scale,
                    spin: spin, isPlaying: isPlaying, reduceMotion: reduceMotion
                )
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
                .glassEffect(.regular.interactive(), in: .circle)
            }
            Spacer()
        }
        .padding(24)
    }

    /// Blurred cover fills the screen behind a heavy dark scrim (static — the
    /// blur renders once per track, not per frame).
    private var backdrop: some View {
        ZStack {
            Color.black
            CoverImage(
                path: entry?.ost.coverImagePath,
                epoch: store.coverEpoch(for: entry?.ost.id)
            )
            .scaledToFill()
            .blur(radius: 70)
            .opacity(0.5)
            Color.black.opacity(0.55)
            RadialGradient(
                colors: [accent.opacity(0.18), .clear],
                center: .center, startRadius: 60, endRadius: 700
            )
        }
        .ignoresSafeArea()
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

/// The radial spectrum: 24 bands mirrored into 48 spokes around a spinning
/// vinyl cover. Fixed diameter so the ring and cover always stay proportional
/// regardless of window size (the free-floating version let the ring outgrow
/// the cover on large displays).
private struct SpectrumRing: View {
    let store: AppStore
    let accent: Color
    let diameter: CGFloat
    let spin: VinylSpin
    let isPlaying: Bool
    let reduceMotion: Bool

    var body: some View {
        let coverSize = diameter * 0.5
        let innerRadius = diameter * 0.30
        let maxLength = diameter * 0.17
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isPlaying)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                Canvas { context, size in
                    var bands = store.player.spectrum.snapshot()
                    let isLive = bands.contains { $0 > 0.004 }
                    if !isLive {
                        guard isPlaying else { return }
                        // Same synthetic shimmer fallback as SpectrumView.
                        bands = (0..<SpectrumEngine.bandCount).map { i in
                            let phase = Double(i) * 0.55
                            let wave = sin(now * 2.1 + phase) * 0.5 + sin(now * 3.7 - phase * 0.8) * 0.5
                            return Float(0.06 + 0.05 * (wave * 0.5 + 0.5))
                        }
                    }
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    let spokes = bands + bands.reversed()   // symmetric ring
                    let baseRotation = reduceMotion ? 0 : now * 0.15
                    var path = Path()
                    for (i, raw) in spokes.enumerated() {
                        let level = CGFloat(pow(Double(raw), 0.8))
                        let angle = baseRotation + Double(i) / Double(spokes.count) * 2 * .pi
                        let length = max(3, level * maxLength)
                        path.move(to: CGPoint(
                            x: center.x + Foundation.cos(angle) * innerRadius,
                            y: center.y + Foundation.sin(angle) * innerRadius
                        ))
                        path.addLine(to: CGPoint(
                            x: center.x + Foundation.cos(angle) * (innerRadius + length),
                            y: center.y + Foundation.sin(angle) * (innerRadius + length)
                        ))
                    }
                    context.stroke(
                        path,
                        with: .linearGradient(
                            Gradient(colors: [accent, Theme.pink]),
                            startPoint: CGPoint(x: 0, y: size.height),
                            endPoint: CGPoint(x: size.width, y: 0)
                        ),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                }

                CoverImage(
                    path: store.nowPlayingEntry?.ost.coverImagePath,
                    epoch: store.coverEpoch(for: store.nowPlayingEntry?.ost.id)
                )
                .aspectRatio(1, contentMode: .fill)
                .frame(width: coverSize, height: coverSize)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 2))
                .overlay(Circle().fill(Color.black.opacity(0.85)).frame(width: coverSize * 0.07, height: coverSize * 0.07))
                .rotationEffect(.degrees(spin.angle(at: timeline.date, spinning: isPlaying && !reduceMotion)))
                .shadow(color: accent.opacity(0.4), radius: 30)
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

/// Freeze-in-place platter physics, shared across both layouts so the record
/// doesn't jump when lyrics arrive and the ring re-docks.
final class VinylSpin {
    private var angleDegrees: Double = 0
    private var lastDate: Date?

    func angle(at date: Date, spinning: Bool) -> Double {
        defer { lastDate = date }
        guard spinning, let last = lastDate else { return angleDegrees }
        let dt = min(0.5, date.timeIntervalSince(last))
        angleDegrees = (angleDegrees + dt * 30).truncatingRemainder(dividingBy: 360)
        return angleDegrees
    }
}
