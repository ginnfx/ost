// The audio visualizer: a GPU-backed Canvas polling SpectrumEngine at display
// rate inside TimelineView(.animation). Real FFT bands when the tap delivers;
// a gentle synthetic wave when audio is playing but tap data never arrived
// (some stream types can't be tapped) so the bar never looks dead.

import SwiftUI

struct SpectrumView: View {
    let engine: SpectrumEngine
    let accent: Color
    var isPlaying = false

    var body: some View {
        // Paused whenever not actively playing — this canvas used to tick at
        // 60fps forever once the bar existed (even stopped), dragging the whole
        // glass bar through a re-composite every frame. 30fps reads the same.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isPlaying)) { timeline in
            Canvas { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                var bands = engine.snapshot()
                let isLive = bands.contains { $0 > 0.004 }
                if !isLive {
                    guard isPlaying else { return }
                    // Fallback shimmer: two slow sines, clearly "idle" energy.
                    bands = (0..<SpectrumEngine.bandCount).map { i in
                        let phase = Double(i) * 0.55
                        let wave = sin(now * 2.1 + phase) * 0.5 + sin(now * 3.7 - phase * 0.8) * 0.5
                        return Float(0.06 + 0.05 * (wave * 0.5 + 0.5))
                    }
                }

                let count = bands.count
                let spacing: CGFloat = 3
                let barWidth = (size.width - spacing * CGFloat(count - 1)) / CGFloat(count)
                var path = Path()
                for (i, raw) in bands.enumerated() {
                    // Mild gamma keeps quiet detail visible without flattening peaks.
                    let level = CGFloat(pow(Double(raw), 0.8))
                    let height = max(2, level * size.height)
                    let x = CGFloat(i) * (barWidth + spacing)
                    path.addRoundedRect(
                        in: CGRect(x: x, y: size.height - height, width: barWidth, height: height),
                        cornerSize: CGSize(width: 1.5, height: 1.5)
                    )
                }
                context.addFilter(.shadow(color: accent.opacity(0.55), radius: 5))
                context.fill(
                    path,
                    with: .linearGradient(
                        Gradient(colors: [accent, Theme.pink]),
                        startPoint: CGPoint(x: 0, y: size.height),
                        endPoint: CGPoint(x: 0, y: 0)
                    )
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
