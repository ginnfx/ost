import SwiftUI

/// An optional player takeover. Lyrics appear only when LRCLIB can verify both
/// the track title and its soundtrack album against the OST metadata.
struct VisualizerView: View {
    let store: AppStore
    var onClose: () -> Void

    @State private var lyrics: [LyricLine]?
    @State private var lyricsOstID: Int?

    private var entry: RankEntry? { store.nowPlayingEntry }
    private var isPlaying: Bool { store.playback?.status == .playing }
    private var accent: Color {
        entry?.ost.coverAccentHex.map { Color(hex: $0) } ?? Theme.accent
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 760
            ZStack(alignment: .topTrailing) {
                Theme.bg.ignoresSafeArea()
                #if os(iOS)
                VStack(spacing: 14) {
                    trackHeader(compact: true)
                    coverArtwork(size: min(geometry.size.width * 0.42, 176))
                        .frame(maxWidth: .infinity)
                    if let lyrics, !lyrics.isEmpty {
                        SyncedLyricsView(
                            lines: lyrics, player: store.player, isPlaying: isPlaying,
                            accent: accent, scale: 0.55
                        ) { time in Task { await store.seek(to: time) } }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if lyrics == nil {
                        VStack(spacing: 12) {
                            ProgressView().tint(accent)
                            Text("Finding synced lyrics…")
                                .font(.ostBody(13)).foregroundStyle(Theme.textDim)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ContentUnavailableView("No synced lyrics", systemImage: "text.quote",
                                               description: Text("Lyrics aren’t available for this OST."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 62)
                .padding(.bottom, 10)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    transport.padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                }
                #else
                HStack(spacing: compact ? 24 : 56) {
                    VStack(alignment: .leading, spacing: compact ? 20 : 34) {
                        trackHeader(compact: compact)
                        if let lyrics, !lyrics.isEmpty {
                            SyncedLyricsView(lines: lyrics, player: store.player, isPlaying: isPlaying,
                                             accent: accent, scale: compact ? 0.72 : 1) { time in
                                Task { await store.seek(to: time) }
                            }
                        } else { Spacer(minLength: 0); Spacer(minLength: 0) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    if !compact {
                        coverArtwork(size: min(geometry.size.width * 0.28, 340))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .offset(x: lyrics == nil ? -geometry.size.width * 0.20 : 0)
                    }
                }
                .padding(compact ? 24 : 64)
                .overlay(alignment: .bottom) { transport.padding(.bottom, 24) }
                #endif
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .background(Theme.cardSurface, in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .padding(20)
            }
        }
        .task(id: "\(entry?.ost.id ?? -1)|\(store.player.duration > 1)") {
            guard let ost = entry?.ost else {
                lyrics = nil
                lyricsOstID = nil
                return
            }
            if lyricsOstID != ost.id {
                lyrics = nil
                lyricsOstID = ost.id
            }
            let duration = store.player.duration > 1 ? store.player.duration : nil
            lyrics = await LyricsService.shared.lyrics(for: ost, duration: duration)
        }
        .background {
            Button("Close fullscreen player", action: onClose)
                .keyboardShortcut(.escape, modifiers: [])
                .hidden()
        }
        .accessibilityAddTraits(.isModal)
    }

    private func trackHeader(compact: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            if compact {
                coverArtwork(size: 54)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(entry?.ost.title ?? "Nothing playing")
                    .font(.ostDisplay(compact ? 22 : 32, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                Text(entry?.ost.source ?? "")
                    .font(.ostBody(14))
                    .foregroundStyle(Theme.textDim)
            }
            Spacer()
        }
    }

    private var transport: some View {
        HStack(spacing: 14) {
            Text(format(store.player.position))
                .font(.ostMono(11))
                .foregroundStyle(Theme.textDim)
            progressTrack
                .frame(maxWidth: 520)
                .disabled(store.player.duration <= 0)
            Button {
                SoundKit.shared.play(isPlaying ? .pause : .playStart)
                Task {
                    if isPlaying { await store.pause() }
                    else if let id = store.playback?.ostId { await store.play(ostID: id) }
                }
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.playback?.ostId == nil)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 10)
    }

    private var progressTrack: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width - 10, 1)
            let progress = min(max(store.player.position / max(store.player.duration, 0.1), 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.textDim.opacity(0.32)).frame(width: width, height: 3)
                Capsule().fill(accent).frame(width: width * progress, height: 3)
                Circle().fill(Theme.textPrimary).frame(width: 8, height: 8)
                    .offset(x: width * progress - 4)
            }
            .frame(height: 24)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                seek(to: value.location.x, width: geometry.size.width)
            })
            .accessibilityElement()
            .accessibilityLabel("Playback position")
            .accessibilityValue("\(format(store.player.position)) of \(format(store.player.duration))")
            .accessibilityAdjustableAction { direction in
                let change = direction == .increment ? 5.0 : -5.0
                Task { await store.seek(to: max(0, min(store.player.duration, store.player.position + change))) }
            }
        }
        .frame(height: 24)
    }

    private func seek(to x: CGFloat, width: CGFloat) {
        let fraction = min(max(x / max(width, 1), 0), 1)
        Task { await store.seek(to: fraction * store.player.duration) }
    }

    private func coverArtwork(size: CGFloat) -> some View {
        ZStack {
            CoverImage(
                path: entry?.ost.coverImagePath,
                epoch: store.coverEpoch(for: entry?.ost.id)
            )
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(Circle())

            SpectrumView(engine: store.player.spectrum, accent: accent, isPlaying: isPlaying, radial: true)
                .frame(width: size * 1.22, height: size * 1.22)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }
}
