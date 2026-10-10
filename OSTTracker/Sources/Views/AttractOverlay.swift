// The ambient idle screensaver behind AttractModeController: mostly-dark
// drifting cover slides (10s cycle, 1.5s crossfades), pinned to the playing
// OST when there is one. Purely decorative — hit-testing is disabled and the
// controller's event monitor handles waking.

import SwiftUI

struct AttractOverlay: View {
    let store: AppStore

    @State private var slideIndex = 0

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if let entry = currentEntry {
                AttractSlide(
                    entry: entry,
                    epoch: store.coverEpoch(for: entry.ost.id),
                    isNowPlaying: store.nowPlayingEntry?.id == entry.id
                )
                .id("\(entry.ost.id)-\(slideIndex)")
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: slideIndex)
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

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            VStack(spacing: 18) {
                CoverImage(path: entry.ost.coverImagePath, epoch: epoch)
                    .scaledToFit()
                    .frame(width: 320, height: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                if isNowPlaying {
                    Text("NOW PLAYING")
                        .font(.ostMono(11, weight: .medium))
                        .foregroundStyle(Theme.textDim)
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
    }
}
