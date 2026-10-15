import SwiftUI

/// A fine-grained spectral ribbon. The center line and quiet silhouette stay
/// visible while paused; only live playback advances the display timeline.
struct SpectrumView: View {
    let engine: SpectrumEngine
    let accent: Color
    var isPlaying = false
    var radial = false
    var mirrorAroundCenter = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(Theme.visualizerKey) private var visualizerEnabled = false
    @AppStorage(Theme.fxIntensityKey) private var fxIntensity = 1.0
    @AppStorage(Theme.motionKey) private var motionSelection = MotionMode.subtle.rawValue

    private var animates: Bool {
        isPlaying && visualizerEnabled && !reduceMotion && motionSelection != MotionMode.minimal.rawValue
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 45.0, paused: !animates)) { timeline in
            Canvas { context, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                let live = engine.snapshot()
                let hasSignal = live.contains { $0 > 0.006 }
                let count = radial ? 96 : max(48, min(84, Int(size.width / 4.3)))
                let levels = (0..<count).map { index -> CGFloat in
                    let unit = Double(index) / Double(max(count - 1, 1))
                    let sample = mirrorAroundCenter ? abs(unit - 0.5) * 2 : unit
                    let band = sample * Double(max(live.count - 1, 0))
                    let lower = min(Int(band), max(live.count - 1, 0))
                    let upper = min(lower + 1, max(live.count - 1, 0))
                    let blend = band - Double(lower)
                    let measured = live.isEmpty ? 0 : Double(live[lower]) * (1 - blend) + Double(live[upper]) * blend
                    // Ambient motion keeps untappable streams visibly alive.
                    let ambient = animates && !hasSignal
                        ? 0.11 + 0.10 * (sin(now * 3.1 + unit * 13) * sin(now * 1.7 - unit * 21) + 1) / 2
                        : 0
                    let silhouette = 0.035 + 0.045 * pow(max(0, sin(.pi * unit)), 0.7)
                    let edge = 0.22 + 0.78 * pow(max(0, sin(.pi * unit)), 0.42)
                    return CGFloat(max(silhouette, pow(max(measured, ambient), 0.78) * Double(fxIntensity) * edge))
                }

                if radial {
                    drawOrbit(in: &context, size: size, levels: levels)
                } else {
                    drawRibbon(in: &context, size: size, levels: levels)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func drawRibbon(in context: inout GraphicsContext, size: CGSize, levels: [CGFloat]) {
        guard !levels.isEmpty else { return }
        let midY = size.height / 2
        let step = size.width / CGFloat(levels.count)
        let width = max(1.4, step * 0.58)
        var bars = Path()
        var peaks = Path()
        var reflection = Path()
        var sparks = Path()

        for (index, level) in levels.enumerated() {
            let x = (CGFloat(index) + 0.5) * step
            let height = max(3, min(size.height * 0.43, level * size.height * 0.59))
            bars.addRoundedRect(
                in: CGRect(x: x - width / 2, y: midY - height, width: width, height: height * 2),
                cornerSize: CGSize(width: width / 2, height: width / 2)
            )
            if index == 0 {
                peaks.move(to: CGPoint(x: x, y: midY - height))
                reflection.move(to: CGPoint(x: x, y: midY + height))
            } else {
                peaks.addLine(to: CGPoint(x: x, y: midY - height))
                reflection.addLine(to: CGPoint(x: x, y: midY + height))
            }
            if index.isMultiple(of: 9) && level > 0.28 {
                sparks.addEllipse(in: CGRect(x: x - 1.5, y: midY - height - 4,
                                             width: 3, height: 3))
            }
        }

        var glow = context
        glow.addFilter(.shadow(color: accent.opacity(0.38), radius: 11))
        glow.fill(bars, with: .color(accent.opacity(0.24)))
        context.fill(bars, with: .linearGradient(
            Gradient(stops: [
                .init(color: accent.opacity(0.48), location: 0),
                .init(color: accent.opacity(0.94), location: 0.48),
                .init(color: accent.opacity(0.35), location: 1),
            ]), startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)
        ))
        context.stroke(peaks, with: .color(.white.opacity(0.45)), lineWidth: 0.8)
        context.stroke(reflection, with: .color(accent.opacity(0.34)), lineWidth: 0.7)
        context.fill(sparks, with: .color(.white.opacity(0.8)))

        var axis = Path()
        axis.move(to: CGPoint(x: 0, y: midY))
        axis.addLine(to: CGPoint(x: size.width, y: midY))
        context.stroke(axis, with: .color(accent.opacity(0.24)), lineWidth: 0.7)
    }

    private func drawOrbit(in context: inout GraphicsContext, size: CGSize, levels: [CGFloat]) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) * 0.38
        let maximum = min(size.width, size.height) * 0.09
        for (index, level) in levels.enumerated() {
            let angle = CGFloat(index) / CGFloat(levels.count) * .pi * 2 - .pi / 2
            let direction = CGVector(dx: cos(angle), dy: sin(angle))
            let length = max(2, maximum * level * 2.5)
            var ray = Path()
            ray.move(to: CGPoint(x: center.x + direction.dx * radius,
                                 y: center.y + direction.dy * radius))
            ray.addLine(to: CGPoint(x: center.x + direction.dx * (radius + length),
                                    y: center.y + direction.dy * (radius + length)))
            context.stroke(ray, with: .color(accent.opacity(0.45 + Double(min(level, 0.5)))),
                           style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
        }
    }
}
