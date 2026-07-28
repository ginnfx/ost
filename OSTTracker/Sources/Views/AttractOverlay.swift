// The ambient idle screensaver behind AttractModeController: mostly-dark
// drifting cover slides (10s cycle, 1.5s crossfades), pinned to the playing
// OST when there is one. Purely decorative — hit-testing is disabled and the
// controller's event monitor handles waking.

import SwiftUI

struct AttractOverlay: View {
    let store: AppStore

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var slideIndex = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let entry = currentEntry {
                AttractSlide(
                    entry: entry,
                    epoch: store.coverEpoch(for: entry.ost.id),
                    isNowPlaying: store.nowPlayingEntry?.id == entry.id,
                    drift: !reduceMotion
                )
                .id("\(entry.ost.id)-\(slideIndex)")
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 1.5), value: slideIndex)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                // Only advance the roster cycle when nothing is pinned to the
                // screen. A now-playing slide holds still, so its identity never
                // changes and the expensive slide (blur + Ken Burns) is not torn
                // down and rebuilt every 10s — the idle-heat culprit.
                if store.nowPlayingEntry == nil { slideIndex += 1 }
            }
        }
        .accessibilityHidden(true)
    }

    /// The playing OST owns the screen; otherwise cycle the roster in order.
    private var currentEntry: RankEntry? {
        if let playing = store.nowPlayingEntry { return playing }
        let entries = store.leaderboard
        guard !entries.isEmpty else { return nil }
        return entries[slideIndex % entries.count]
    }
}

private struct AttractSlide: View {
    let entry: RankEntry
    let epoch: Int
    let isNowPlaying: Bool
    let drift: Bool

    @State private var drifted = false

    private var accent: Color {
        entry.ost.coverAccentHex.map { Color(hex: $0) } ?? Theme.accent
    }

    var body: some View {
        ZStack {
            CoverImage(path: entry.ost.coverImagePath, epoch: epoch)
                .scaledToFill()
                .blur(radius: 40)
                .opacity(0.35)
                .ignoresSafeArea()
                // Rasterize the fullscreen gaussian once into an offscreen
                // buffer so the animating foreground doesn't force the blur to
                // recompute every frame (major idle-GPU savings).
                .drawingGroup()
            Color.black.opacity(0.6).ignoresSafeArea()

            VStack(spacing: 18) {
                CoverImage(path: entry.ost.coverImagePath, epoch: epoch)
                    .aspectRatio(1, contentMode: .fill)
                    .frame(width: 320, height: 320)
                    .clipShape(ChamferedRect())
                    .overlay(ChamferedRect().stroke(accent.opacity(0.5), lineWidth: 1.5))
                    .shadow(color: accent.opacity(0.35), radius: 40)
                    // Ken Burns drift: one slow 10s swell per slide.
                    .scaleEffect(drifted ? 1.05 : 1.0)
                if isNowPlaying {
                    Text("NOW PLAYING")
                        .font(.ostMono(11, weight: .medium))
                        .foregroundStyle(accent)
                        .kerning(2)
                }
                Text(entry.ost.title)
                    .font(.ostDisplay(30, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if let source = entry.ost.source {
                    Text(source)
                        .font(.ostBody(15))
                        .foregroundStyle(Theme.textDim)
                }
            }
            .padding(40)
        }
        .onAppear {
            guard drift else { return }
            withAnimation(.easeInOut(duration: 10)) { drifted = true }
        }
    }
}
