// The audio visualizer: a GPU-backed Canvas polling SpectrumEngine at display
// rate inside TimelineView(.animation). Real FFT bands when the tap delivers;
// a gentle synthetic wave when audio is playing but tap data never arrived
// (some stream types can't be tapped) so the bar never looks dead.

import SwiftUI

struct SpectrumView: View {
    let engine: SpectrumEngine
    let accent: Color
    var isPlaying = false
    var radial = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(Theme.visualizerKey) private var visualizerEnabled = true
    @AppStorage(Theme.fxIntensityKey) private var fxIntensity = 1.0
    @AppStorage(Theme.motionKey) private var motionSelection = MotionMode.subtle.rawValue

    private var active: Bool {
        isPlaying && visualizerEnabled && !reduceMotion && motionSelection != MotionMode.minimal.rawValue
    }

    var body: some View {
        // Paused whenever not actively playing — this canvas used to tick at
        // 60fps forever once the bar existed (even stopped), dragging the whole
        // glass bar through a re-composite every frame. 30fps reads the same.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active)) { timeline in
            Canvas { context, size in
                guard active else { return }
                let now = timeline.date.timeIntervalSinceReferenceDate
                var bands = engine.snapshot()
                let isLive = bands.contains { $0 > 0.004 }
                if !isLive {
                    guard active else { return }
                    // Fallback shimmer: two slow sines, clearly "idle" energy.
                    bands = (0..<SpectrumEngine.bandCount).map { i in
                        let phase = Double(i) * 0.55
                        let wave = sin(now * 2.1 + phase) * 0.5 + sin(now * 3.7 - phase * 0.8) * 0.5
                        return Float(0.06 + 0.05 * (wave * 0.5 + 0.5))
                    }
                }

                let count = bands.count
                if radial {
                    let center = min(size.width, size.height) / 2
                    let radius = center * 0.82
                    let radialCount = max(72, count * 3)
                    let barWidth = max(3, center * 0.052)
                    for i in 0..<radialCount {
                        let sample = Double(i) / Double(radialCount) * Double(count)
                        let lower = Int(sample) % count
                        let upper = (lower + 1) % count
                        let blend = sample - floor(sample)
                        let raw = Double(bands[lower]) * (1 - blend) + Double(bands[upper]) * blend
                        let level = CGFloat(pow(raw, 0.8))
                        let length = max(2, min(center * 0.18, level * center * 0.42 * CGFloat(fxIntensity)))
                        let angle = Angle.degrees(Double(i) / Double(radialCount) * 360 - 90)
                        var barContext = context
                        barContext.translateBy(x: center, y: center)
                        barContext.rotate(by: angle)
                        var bar = Path()
                        bar.addRoundedRect(
                            in: CGRect(x: radius, y: -barWidth / 2, width: length, height: barWidth),
                            cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2)
                        )
                        barContext.fill(bar, with: .color(accent))
                    }
                    return
                }

                let spacing: CGFloat = 3
                let barWidth = (size.width - spacing * CGFloat(count - 1)) / CGFloat(count)
                var path = Path()
                for (i, raw) in bands.enumerated() {
                    // Mild gamma keeps quiet detail visible without flattening peaks.
                    let level = CGFloat(pow(Double(raw), 0.8))
                    let height = max(2, min(size.height, level * size.height * CGFloat(fxIntensity)))
                    let x = CGFloat(i) * (barWidth + spacing)
                    path.addRoundedRect(
                        in: CGRect(x: x, y: size.height - height, width: barWidth, height: height),
                        cornerSize: CGSize(width: 1.5, height: 1.5)
                    )
                }
                context.fill(
                    path,
                    with: .color(accent)
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
