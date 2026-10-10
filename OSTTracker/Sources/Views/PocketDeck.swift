import SwiftUI

/// A small cassette that moves with playback. The meter uses live FFT bands;
/// reels still turn if a stream does not expose audio samples to the tap.
struct PocketDeck: View {
    let store: AppStore
    let accent: Color
    let spin: ReelSpin
    let isPlaying: Bool
    let still: Bool
    let intensity: Double
    var compact = false

    private var active: Bool { isPlaying && !still }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            ZStack {
                TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !active)) { timeline in
                    let angle = spin.angle(at: timeline.date, spinning: active)
                    let bands = active ? store.player.spectrum.snapshot() : []
                    Canvas { context, size in
                        drawDeck(context, size: size, angle: angle, bands: bands)
                    }
                }

                if !compact {
                    CoverImage(
                        path: store.nowPlayingEntry?.ost.coverImagePath,
                        epoch: store.coverEpoch(for: store.nowPlayingEntry?.ost.id)
                    )
                    .aspectRatio(1, contentMode: .fill)
                    .frame(width: width * 0.18, height: height * 0.27)
                    .clipShape(RoundedRectangle(cornerRadius: max(2, width * 0.008)))
                    .position(x: width * 0.17, y: height * 0.24)

                    VStack(alignment: .leading, spacing: max(2, height * 0.012)) {
                        Text("SIDE A  /  OST TRACKER")
                            .font(.ostMono(max(8, height * 0.036), weight: .bold))
                            .foregroundStyle(Theme.bg)
                        Text(store.nowPlayingEntry?.ost.title ?? "")
                            .font(.ostDisplay(max(12, height * 0.075), weight: .bold))
                            .foregroundStyle(Theme.bg)
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(width: width * 0.58, height: height * 0.27, alignment: .leading)
                    .position(x: width * 0.64, y: height * 0.24)
                }
            }
        }
        .aspectRatio(1.47, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isPlaying ? "Cassette visualizer playing" : "Cassette visualizer paused")
    }

    private func drawDeck(_ context: GraphicsContext, size: CGSize, angle: Double, bands: [Float]) {
        let w = size.width
        let h = size.height
        guard w > 0, h > 0 else { return }

        let caseRect = CGRect(x: 1, y: 1, width: w - 2, height: h - 2)
        let casePath = Path(roundedRect: caseRect, cornerRadius: max(4, w * 0.025))
        context.fill(casePath, with: .color(Theme.cardSurface))
        context.stroke(casePath, with: .color(Theme.separator), lineWidth: max(1, w * 0.004))

        let label = CGRect(x: w * 0.055, y: h * 0.065, width: w * 0.89, height: h * 0.35)
        context.fill(Path(roundedRect: label, cornerRadius: max(2, w * 0.012)),
                     with: .color(Color(hex: "#D6D8D2")))
        context.fill(Path(CGRect(x: label.minX, y: label.maxY - h * 0.023,
                                 width: label.width, height: h * 0.023)), with: .color(accent))

        let window = CGRect(x: w * 0.075, y: h * 0.475, width: w * 0.85, height: h * 0.31)
        context.fill(Path(roundedRect: window, cornerRadius: max(2, w * 0.016)),
                     with: .color(Theme.bg))

        let radius = min(w * 0.125, h * 0.145)
        let left = CGPoint(x: w * 0.29, y: h * 0.63)
        let right = CGPoint(x: w * 0.71, y: h * 0.63)
        drawReel(context, center: left, radius: radius, angle: angle)
        drawReel(context, center: right, radius: radius, angle: -angle)

        // The tape path gives the cassette a little smile without drifting
        // around the screen. Bass nudges its midpoint only when FFT is present.
        let bass = bands.prefix(5).reduce(0.0) { $0 + Double($1) } / 5.0
        var tape = Path()
        tape.move(to: CGPoint(x: left.x, y: left.y + radius * 0.65))
        tape.addQuadCurve(to: CGPoint(x: right.x, y: right.y + radius * 0.65),
                          control: CGPoint(x: w * 0.5, y: h * CGFloat(0.82 + min(0.035, bass * 0.06))))
        context.stroke(tape, with: .color(accent.opacity(0.8)),
                       style: StrokeStyle(lineWidth: max(1, w * 0.005), lineCap: .round))

        let count = 12
        for index in 0..<count {
            let bandStart = index * 2
            let raw = bands.count > bandStart + 1
                ? (Double(bands[bandStart]) + Double(bands[bandStart + 1])) * 0.5 : 0
            let level = min(1, max(0, raw * max(0, intensity) * 1.6))
            let barHeight = h * CGFloat(0.018 + 0.07 * level)
            let x = w * (0.16 + CGFloat(index) * 0.062)
            let bar = CGRect(x: x, y: h * 0.91 - barHeight,
                             width: max(2, w * 0.033), height: barHeight)
            context.fill(Path(roundedRect: bar, cornerRadius: max(1, w * 0.004)),
                         with: .color(level > 0.02 ? accent : Theme.textDim.opacity(0.4)))
        }
    }

    private func drawReel(_ context: GraphicsContext, center: CGPoint,
                          radius: CGFloat, angle: Double) {
        let outer = CGRect(x: center.x - radius, y: center.y - radius,
                           width: radius * 2, height: radius * 2)
        context.fill(Path(ellipseIn: outer), with: .color(Theme.cardSurface))
        context.stroke(Path(ellipseIn: outer), with: .color(Theme.textDim.opacity(0.7)),
                       lineWidth: max(1, radius * 0.045))
        var spokes = Path()
        for index in 0..<5 {
            let theta = angle * .pi / 180 + Double(index) * 2 * .pi / 5
            spokes.move(to: CGPoint(x: center.x + CGFloat(cos(theta)) * radius * 0.28,
                                    y: center.y + CGFloat(sin(theta)) * radius * 0.28))
            spokes.addLine(to: CGPoint(x: center.x + CGFloat(cos(theta)) * radius * 0.77,
                                       y: center.y + CGFloat(sin(theta)) * radius * 0.77))
        }
        context.stroke(spokes, with: .color(Color(hex: "#D6D8D2")),
                       style: StrokeStyle(lineWidth: max(1, radius * 0.11), lineCap: .round))
        let hub = CGRect(x: center.x - radius * 0.21, y: center.y - radius * 0.21,
                         width: radius * 0.42, height: radius * 0.42)
        context.fill(Path(ellipseIn: hub), with: .color(accent))
        let spindle = CGRect(x: center.x - radius * 0.065, y: center.y - radius * 0.065,
                             width: radius * 0.13, height: radius * 0.13)
        context.fill(Path(ellipseIn: spindle), with: .color(Theme.bg))
    }
}

/// Keeps reel angles steady when playback pauses or the lyrics layout changes.
final class ReelSpin {
    private var angleDegrees: Double = 0
    private var lastDate: Date?

    func angle(at date: Date, spinning: Bool) -> Double {
        defer { lastDate = date }
        guard spinning, let lastDate else { return angleDegrees }
        let elapsed = min(0.5, max(0, date.timeIntervalSince(lastDate)))
        angleDegrees = (angleDegrees + elapsed * 75).truncatingRemainder(dividingBy: 360)
        return angleDegrees
    }
}
