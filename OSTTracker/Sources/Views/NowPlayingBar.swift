// Floating transport chrome, rendered in Liquid Glass like the rest of the
// app's chrome and panels (see RootView header for the glass policy).
// Reads playbackState/resolution from the store; audio itself runs in PlayerSink.

import SwiftUI

struct NowPlayingBar: View {
    let store: AppStore
    /// Opens the fullscreen visualizer (expand button, or tapping the spectrum).
    var onExpand: () -> Void = {}
    /// False when the bar is fully covered (visualizer/attract overlay up); its
    /// spectrum + vinyl stop animating so they don't burn frames off-screen.
    var active: Bool = true

    @State private var scrubbing = false
    @State private var scrubValue = 0.0

    private var status: PlaybackStatus { store.playback?.status ?? .idle }

    /// Reads live playback position unless the user is actively dragging.
    private var progress: Binding<Double> {
        Binding(
            get: { scrubbing ? scrubValue : store.player.position },
            set: { scrubValue = $0 }
        )
    }

    var body: some View {
        GlassEffectContainer {
            VStack(spacing: 6) {
                HStack(spacing: 14) {
                    artwork
                    titleBlock
                    Spacer(minLength: 12)
                    transport
                }
                SpectrumView(
                    engine: store.player.spectrum,
                    accent: accentColor,
                    isPlaying: status == .playing && active
                )
                .frame(height: 30)
                .contentShape(Rectangle())
                .onTapGesture {
                    SoundKit.shared.play(.select)
                    onExpand()
                }
                scrubber
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: ChamferedRect(cut: 12))
        }
        .frame(maxWidth: 640)
    }

    private var scrubber: some View {
        Slider(value: progress, in: 0...max(store.player.duration, 0.1)) { editing in
            scrubbing = editing
            if !editing { Task { await store.seek(to: scrubValue) } }
        }
        .controlSize(.mini)
        .tint(Theme.accent)
        .disabled(store.player.duration <= 0)
        .opacity(store.player.duration <= 0 ? 0.35 : 1)
    }

    private var artwork: some View {
        VinylArtwork(
            path: store.nowPlayingEntry?.ost.coverImagePath,
            epoch: store.coverEpoch(for: store.nowPlayingEntry?.ost.id),
            isPlaying: status == .playing && active
        )
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(store.nowPlayingEntry?.ost.title ?? "—")
                .font(.ostDisplay(13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            if status == .resolving {
                let phase = store.playback?.ostId.flatMap { store.resolutionPhase[$0] }
                Text("resolving: \(phase?.rawValue ?? "starting")")
                    .font(.ostMono(10))
                    .foregroundStyle(Theme.accent)
                    .contentTransition(.opacity)
            } else {
                Text(timeReadout)
                    .font(.ostMono(10))
                    .foregroundStyle(Theme.textDim)
                    .monospacedDigit()
            }
        }
    }

    /// The playing OST's cover accent drives the spectrum gradient, matching
    /// the accent treatment on its card and detail view.
    private var accentColor: Color {
        store.nowPlayingEntry?.ost.coverAccentHex.map { Color(hex: $0) } ?? Theme.accent
    }

    private var timeReadout: String {
        "\(format(store.player.position)) / \(format(store.player.duration))"
    }

    // Play/pause and stop carry .interactive() glass specifically so they
    // respond to press/touch state (scale + illumination), while the bar itself
    // is plain .regular glass. They live inside the bar's GlassEffectContainer,
    // so the per-button glass shares the bar's sampling region instead of
    // stacking as glass-on-glass.
    private var transport: some View {
        HStack(spacing: 10) {
            Button {
                SoundKit.shared.play(status == .playing ? .pause : .playStart)
                Task {
                    if status == .playing {
                        await store.pause()
                    } else if let id = store.playback?.ostId {
                        await store.play(ostID: id)
                    }
                }
            } label: {
                Image(systemName: status == .playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 40, height: 30)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive().tint(Theme.accent.opacity(0.2)), in: .capsule)
            .disabled(status == .resolving)

            Button {
                SoundKit.shared.play(.stop)
                Task { await store.stop() }
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 34, height: 30)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)

            Button {
                SoundKit.shared.play(.select)
                onExpand()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
            .help("Fullscreen visualizer")
        }
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }
}

/// The bar's cover, pressed as a record: circular with a spindle hole, spinning
/// at ~12s/rev while playing (continuous loops are the one sanctioned use of
/// linear motion), frozen in place on pause. Reduce Motion: never spins.
private struct VinylArtwork: View {
    let path: String?
    let epoch: Int
    let isPlaying: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin = SpinTracker()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isPlaying || reduceMotion)) { timeline in
            CoverImage(path: path, epoch: epoch)
                .aspectRatio(1, contentMode: .fill)
                .frame(width: 40, height: 40)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1))
                .overlay(Circle().fill(Color.black.opacity(0.85)).frame(width: 7, height: 7))
                .rotationEffect(.degrees(spin.angle(at: timeline.date, spinning: isPlaying && !reduceMotion)))
        }
    }
}

/// Accumulates rotation only while playing, so pausing freezes the platter
/// exactly where it stopped. Plain class — never invalidates the view.
private final class SpinTracker {
    private var angleDegrees: Double = 0
    private var lastDate: Date?

    func angle(at date: Date, spinning: Bool) -> Double {
        defer { lastDate = date }
        guard spinning, let last = lastDate else { return angleDegrees }
        let dt = min(0.5, date.timeIntervalSince(last))   // clamp resume jumps
        angleDegrees = (angleDegrees + dt * 30).truncatingRemainder(dividingBy: 360)
        return angleDegrees
    }
}
