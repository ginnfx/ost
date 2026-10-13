// Playback controls read store state; PlayerSink owns the audio stream.

import SwiftUI

struct NowPlayingBar: View {
    let store: AppStore
    /// False when the bar is covered by the attract overlay.
    var active: Bool = true
    /// macOS keeps the transport in the window even before a track is selected.
    var desktop: Bool = false
    var onExpand: () -> Void = {}

    @State private var scrubbing = false
    @State private var scrubValue = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(Theme.visualizerKey) private var visualizerEnabled = true
    @AppStorage(Theme.motionKey) private var motionSelection = MotionMode.subtle.rawValue

    private var status: PlaybackStatus { store.playback?.status ?? .idle }
    private var hasTrack: Bool { store.playback?.ostId != nil && status != .idle }
    private var transportHitSize: CGFloat { desktop ? 36 : 44 }
    private var showVisualizer: Bool {
        visualizerEnabled && hasTrack && !reduceMotion && motionSelection != MotionMode.minimal.rawValue
    }

    /// Reads live playback position unless the user is actively dragging.
    private var progress: Binding<Double> {
        Binding(
            get: { scrubbing ? scrubValue : store.player.position },
            set: { scrubValue = $0 }
        )
    }

    var body: some View {
        Group {
            #if os(macOS)
            if desktop { desktopBody } else { compactBody }
            #else
            compactBody
            #endif
        }
    }

    private var compactBody: some View {
        VStack(spacing: 6) {
            HStack(spacing: 14) {
                artwork
                titleBlock
                Spacer(minLength: 12)
                transport
            }
            if showVisualizer {
                SpectrumView(
                    engine: store.player.spectrum,
                    accent: accentColor,
                    isPlaying: status == .playing && active
                )
                .frame(height: 30)
            }
            scrubber
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 640)
        .background(Theme.bgRaised, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.separator, lineWidth: 1))
    }

    #if os(macOS)
    private var desktopBody: some View {
        HStack(spacing: 24) {
            HStack(spacing: 12) {
                CoverImage(
                    path: store.nowPlayingEntry?.ost.coverImagePath,
                    epoch: store.coverEpoch(for: store.nowPlayingEntry?.ost.id)
                )
                .scaledToFit()
                .frame(width: 48, height: 48)
                .background(Theme.bg)
                .clipShape(RoundedRectangle(cornerRadius: 5))

                VStack(alignment: .leading, spacing: 3) {
                    Text(store.nowPlayingEntry?.ost.title ?? "Nothing playing")
                        .font(.ostBody(13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(desktopSubtitle)
                        .font(.ostBody(11))
                        .foregroundStyle(Theme.textDim)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 3) {
                HStack(spacing: 8) {
                    playPauseButton
                    stopButton
                }
                if showVisualizer {
                    SpectrumView(
                        engine: store.player.spectrum,
                        accent: accentColor,
                        isPlaying: status == .playing && active
                    )
                    .frame(height: 14)
                }
                HStack(spacing: 8) {
                    Text(format(store.player.position))
                    seekSlider
                    Text(format(store.player.duration))
                }
                .font(.ostMono(10))
                .foregroundStyle(Theme.textDim)
                .monospacedDigit()
            }
            .frame(maxWidth: 470)

            HStack(spacing: 10) {
                expandButton
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textDim)
                    .accessibilityHidden(true)
                Slider(
                    value: Binding(
                        get: { store.player.volume },
                        set: { store.player.setVolume($0) }
                    ),
                    in: 0...1
                )
                .controlSize(.small)
                .accessibilityLabel("Volume")
            }
            .frame(minWidth: 150, maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 24)
        .frame(height: 92)
        .frame(maxWidth: .infinity)
        .background(Theme.bgRaised)
        .overlay(alignment: .top) { Theme.separator.frame(height: 1) }
    }

    private var desktopSubtitle: String {
        if status == .resolving {
            let phase = store.playback?.ostId.flatMap { store.resolutionPhase[$0] }
            return "Resolving \(phase?.rawValue ?? "track")"
        }
        return store.nowPlayingEntry?.ost.source ?? (hasTrack ? "OST" : "Choose an OST from Roster")
    }
    #endif

    private var scrubber: some View {
        seekSlider
            .controlSize(.mini)
    }

    private var seekSlider: some View {
        Slider(value: progress, in: 0...max(store.player.duration, 0.1)) { editing in
            scrubbing = editing
            if !editing { Task { await store.seek(to: scrubValue) } }
        }
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
            Text(store.nowPlayingEntry?.ost.title ?? "Loading track")
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

    private var accentColor: Color {
        Theme.accent
    }

    private var timeReadout: String {
        "\(format(store.player.position)) / \(format(store.player.duration))"
    }

    private var transport: some View {
        HStack(spacing: 10) {
            playPauseButton
            stopButton
            expandButton
        }
    }

    private var expandButton: some View {
        Button(action: onExpand) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textDim)
                .frame(width: transportHitSize, height: transportHitSize)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Open fullscreen player")
        .help("Open fullscreen player")
        .disabled(!hasTrack)
    }

    private var playPauseButton: some View {
        Button {
            SoundKit.shared.play(status == .playing ? .pause : .playStart)
            Task {
                if status == .playing { await store.pause() }
                else if let id = store.playback?.ostId { await store.play(ostID: id) }
            }
        } label: {
            Image(systemName: status == .playing ? "pause.fill" : "play.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: transportHitSize, height: transportHitSize)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(status == .playing ? "Pause" : "Play")
        .disabled(!hasTrack || status == .resolving)
    }

    private var stopButton: some View {
        Button {
            SoundKit.shared.play(.stop)
            Task { await store.stop() }
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: transportHitSize, height: transportHitSize)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Stop")
        .disabled(!hasTrack)
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }
}

/// Album artwork in the compact player.
private struct VinylArtwork: View {
    let path: String?
    let epoch: Int
    let isPlaying: Bool

    var body: some View {
        CoverImage(path: path, epoch: epoch)
            .scaledToFit()
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
