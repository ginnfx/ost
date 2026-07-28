// Spotify-style synced lyrics: big bold lines, the current line full-bright,
// sung lines dimmed further than upcoming ones, spring-scrolled to center as
// playback advances, tap any line to seek. Line-level sync (the store's
// position ticks twice a second — plenty for lines that last seconds).

import SwiftUI

struct SyncedLyricsView: View {
    let lines: [LyricLine]
    let player: PlayerSink
    let isPlaying: Bool
    let accent: Color
    /// Uniform window-size factor from VisualizerView — lyric type and spacing
    /// track the rest of the takeover between windowed and fullscreen.
    var scale: CGFloat = 1
    let onSeek: (Double) -> Void

    var body: some View {
        // While playing: tick 5x/s and extrapolate wall-clock time since the
        // last 0.5s position update so line changes land on the beat. While
        // paused/stopped: render statically — .periodic has no `paused:`, so a
        // live TimelineView would keep rebuilding the whole list on silence.
        if isPlaying {
            TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                lyricsList(currentIndex: currentIndex(extrapolate: true))
            }
        } else {
            lyricsList(currentIndex: currentIndex(extrapolate: false))
        }
    }

    /// Index of the last line whose timestamp has passed. When playing we
    /// extrapolate wall-clock time since the last 0.5s position tick so the
    /// highlight lands on the beat; when paused we read the raw position.
    private func currentIndex(extrapolate: Bool) -> Int? {
        let elapsed = extrapolate ? max(0, CFAbsoluteTimeGetCurrent() - player.positionUpdatedAt) : 0
        let position = player.position + min(elapsed, 1.0)
        return lines.lastIndex { $0.time <= position + 0.2 }
    }

    private func lyricsList(currentIndex: Int?) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24 * scale) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line.text)
                            .font(.ostDisplay(30 * scale, weight: .bold))
                            .foregroundStyle(color(for: index, current: currentIndex))
                            .scaleEffect(index == currentIndex ? 1.0 : 0.97, anchor: .leading)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture { onSeek(line.time) }
                    }
                }
                .padding(.vertical, 180 * scale)   // room to center first/last lines
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeOut(duration: 0.25), value: currentIndex)
            }
            .onChange(of: currentIndex) { _, new in
                guard let new else { return }
                withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) {
                    proxy.scrollTo(new, anchor: .center)
                }
            }
            .onAppear {
                if let current = currentIndex { proxy.scrollTo(current, anchor: .center) }
            }
            // Lines dissolve at the edges instead of clipping.
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.12),
                        .init(color: .black, location: 0.88),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            )
        }
    }

    private func color(for index: Int, current: Int?) -> Color {
        guard let current else { return Color.white.opacity(0.45) }
        if index == current { return Theme.textPrimary }
        return Color.white.opacity(index < current ? 0.28 : 0.45)
    }
}
