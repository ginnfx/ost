import SwiftUI
#if os(iOS)
import AVKit
#endif

/// An optional player takeover. Lyrics appear only when LRCLIB can verify both
/// the track title and its soundtrack album against the OST metadata.
struct VisualizerView: View {
    let store: AppStore
    var onClose: () -> Void

    @State private var lyrics: LyricsResult?
    @State private var lyricsOstID: Int?
    #if os(iOS)
    @State private var scrubbing = false
    @State private var scrubPosition = 0.0
    @AppStorage(Theme.visualizerKey) private var visualizerEnabled = false
    #endif

    private var entry: RankEntry? { store.nowPlayingEntry }
    private var isPlaying: Bool { store.playback?.status == .playing }
    private var accent: Color {
        entry?.ost.coverAccentHex.map { Color(hex: $0) } ?? Theme.accent
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 760
            ZStack(alignment: .topTrailing) {
                #if os(iOS)
                phoneBackdrop(in: geometry.size)
                phonePlayer(in: geometry.size)
                #else
                Theme.bg.ignoresSafeArea()
                HStack(spacing: compact ? 24 : 56) {
                    VStack(alignment: .leading, spacing: compact ? 20 : 34) {
                        trackHeader(compact: compact)
                        if let lines = lyrics?.synced, !lines.isEmpty {
                            SyncedLyricsView(lines: lines, player: store.player, isPlaying: isPlaying,
                                             accent: accent, scale: compact ? 0.72 : 1) { time in
                                Task { await store.seek(to: time) }
                            }
                        } else if let plain = lyrics?.plain {
                            plainLyrics(plain)
                        } else {
                            SpectrumView(engine: store.player.spectrum, accent: accent,
                                         isPlaying: isPlaying, mirrorAroundCenter: true)
                                .frame(maxWidth: 620)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
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
                #if os(macOS)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .background(Theme.cardSurface, in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .padding(20)
                #endif
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
            let result = await LyricsService.shared.lyrics(for: ost, duration: duration)
            guard !Task.isCancelled else { return }
            lyrics = result
        }
        .background {
            Button("Close fullscreen player", action: onClose)
                .keyboardShortcut(.escape, modifiers: [])
                .hidden()
        }
        .accessibilityAddTraits(.isModal)
    }

    #if os(iOS)
    private var hasLyrics: Bool {
        lyrics?.synced?.isEmpty == false || lyrics?.plain != nil
    }

    private func phoneBackdrop(in size: CGSize) -> some View {
        ZStack {
            Theme.bg
            CoverImage(path: entry?.ost.coverImagePath,
                       epoch: store.coverEpoch(for: entry?.ost.id))
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .blur(radius: 75)
                .opacity(0.25)
            LinearGradient(colors: [Theme.bg.opacity(0.36), Theme.bg.opacity(0.62), Theme.bg.opacity(0.95)],
                           startPoint: .top, endPoint: .bottom)
            accent.opacity(0.06)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .ignoresSafeArea()
    }

    private func phonePlayer(in size: CGSize) -> some View {
        let showSpectrum = visualizerEnabled && !hasLyrics
        let artSize = min(size.width - 48, size.height * (showSpectrum ? 0.34 : 0.46), 390)
        return VStack(spacing: 0) {
            phoneTopBar
                .padding(.top, 12)

            if let lines = lyrics?.synced, !lines.isEmpty {
                phoneTrackInfo(compact: true)
                    .padding(.top, 28)
                SyncedLyricsView(lines: lines, player: store.player, isPlaying: isPlaying,
                                 accent: accent, scale: 0.88) { time in
                    Task { await store.seek(to: time) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 24)
            } else if let plain = lyrics?.plain {
                phoneTrackInfo(compact: true)
                    .padding(.top, 28)
                plainLyrics(plain)
                    .padding(.vertical, 20)
            } else {
                Spacer(minLength: 16)
                phoneArtwork(size: artSize)
                if showSpectrum {
                    SpectrumView(engine: store.player.spectrum, accent: accent,
                                 isPlaying: isPlaying, mirrorAroundCenter: true)
                        .frame(height: 94)
                        .padding(.top, 18)
                }
                Spacer(minLength: 18)
                phoneTrackInfo(compact: false)
                    .padding(.bottom, 22)
            }
            phoneTransport
                .padding(.bottom, 22)
        }
        .frame(maxWidth: 560)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var phoneTopBar: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Close player")
            Spacer()
            Text("NOW PLAYING")
                .font(.ostBody(11, weight: .semibold))
                .tracking(1.8)
                .foregroundStyle(Theme.textPrimary.opacity(0.82))
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
    }

    private func phoneArtwork(size: CGFloat) -> some View {
        CoverImage(path: entry?.ost.coverImagePath,
                   epoch: store.coverEpoch(for: entry?.ost.id))
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.42), radius: 28, y: 20)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }

    private func phoneTrackInfo(compact: Bool) -> some View {
        HStack(alignment: .center, spacing: 14) {
            if compact {
                CoverImage(path: entry?.ost.coverImagePath,
                           epoch: store.coverEpoch(for: entry?.ost.id))
                    .scaledToFill()
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(entry?.ost.title ?? "Nothing playing")
                    .font(.ostDisplay(compact ? 21 : 28, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                Text(entry?.ost.source ?? "")
                    .font(.ostBody(compact ? 13 : 16))
                    .foregroundStyle(Theme.textDim)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var phoneTransport: some View {
        VStack(spacing: 8) {
            Slider(value: Binding(
                get: { scrubbing ? scrubPosition : store.player.position },
                set: { scrubPosition = $0 }
            ), in: 0...max(store.player.duration, 0.1)) { editing in
                scrubbing = editing
                if !editing { Task { await store.seek(to: scrubPosition) } }
            }
            .tint(accent)
            .disabled(store.player.duration <= 0)
            .accessibilityLabel("Playback position")
            HStack {
                Text(format(scrubbing ? scrubPosition : store.player.position))
                Spacer()
                Text(format(store.player.duration))
            }
            .font(.ostMono(11))
            .monospacedDigit()
            .foregroundStyle(Theme.textDim)

            GlassEffectContainer(spacing: 24) {
                HStack {
                    Button { Task { await store.stop(); onClose() } } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 14))
                            .frame(width: 48, height: 48)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Stop")
                    Spacer()
                    Button {
                        SoundKit.shared.play(isPlaying ? .pause : .playStart)
                        Task {
                            if isPlaying { await store.pause() }
                            else if let id = store.playback?.ostId { await store.play(ostID: id) }
                        }
                    } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .frame(width: 68, height: 68)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .tint(accent)
                    .accessibilityLabel(isPlaying ? "Pause" : "Play")
                    Spacer()
                    AirPlayRouteButton()
                        .frame(width: 48, height: 48)
                        .glassEffect(.regular, in: Circle())
                        .accessibilityLabel("Audio output")
                }
            }
            .padding(.top, 16)
        }
    }
    #endif

    private func plainLyrics(_ text: String) -> some View {
        ScrollView(showsIndicators: false) {
            Text(text)
                .font(.ostDisplay(19, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineSpacing(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            #if os(iOS)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textDim)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close player")
            #endif
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
        CoverImage(path: entry?.ost.coverImagePath,
                   epoch: store.coverEpoch(for: entry?.ost.id))
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(Circle())
            .accessibilityHidden(true)
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }
}

#if os(iOS)
private struct AirPlayRouteButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .white
        picker.activeTintColor = .white
        picker.prioritizesVideoDevices = false
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif
