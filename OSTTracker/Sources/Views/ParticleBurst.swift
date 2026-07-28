// Perfect-10 celebration. Research-backed restraint: a single ~1.8s decaying
// burst fired only at the moment a 10 is set, drawn over an interactive UI
// (never blocks input), and Reduce Motion swaps particles for a soft fading
// glow. Canvas + TimelineView leaf, same pattern as the visualizer.

import SwiftUI

struct ParticleBurst: View {
    /// Bump this to fire a burst; 0/unchanged renders nothing.
    let trigger: Int
    let accent: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var firedAt: Date?
    @State private var particles: [Particle] = []

    private static let life: TimeInterval = 1.8
    private static let count = 26

    struct Particle {
        let angle: Double      // launch direction, radians
        let speed: Double      // points/second
        let size: Double
        let paletteIndex: Int  // accent / gold / pink
    }

    var body: some View {
        Group {
            if firedAt != nil {
                if reduceMotion {
                    Circle()
                        .fill(accent.opacity(0.35))
                        .blur(radius: 18)
                        .task { await expire(after: 0.8) }
                } else {
                    burstCanvas
                        .task(id: firedAt) { await expire(after: Self.life) }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: trigger) { _, new in
            guard new > 0 else { return }
            fire()
        }
    }

    private var burstCanvas: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            Canvas { context, size in
                guard let firedAt else { return }
                let t = timeline.date.timeIntervalSince(firedAt)
                guard t >= 0, t < Self.life else { return }
                let origin = CGPoint(x: size.width / 2, y: size.height / 2)
                let palette = [accent, Theme.gold, Theme.pink]
                let progress = t / Self.life
                for particle in particles {
                    // Fast launch that decelerates, plus gravity pulling down.
                    let distance = particle.speed * t * (1 - 0.45 * progress)
                    let x = origin.x + cos(particle.angle) * distance
                    let y = origin.y + sin(particle.angle) * distance + 170 * t * t
                    let rect = CGRect(
                        x: x, y: y,
                        width: particle.size, height: particle.size
                    )
                    context.opacity = 1 - progress
                    context.fill(
                        Path(ellipseIn: rect),
                        with: .color(palette[particle.paletteIndex % palette.count])
                    )
                }
            }
        }
    }

    private func fire() {
        particles = (0..<Self.count).map { i in
            Particle(
                angle: Double.random(in: 0..<(2 * .pi)),
                speed: Double.random(in: 70...240),
                size: Double.random(in: 3...7),
                paletteIndex: i
            )
        }
        firedAt = Date()
    }

    /// Clears the trigger state so the TimelineView tears down entirely —
    /// a finished burst costs zero frames.
    private func expire(after seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
        firedAt = nil
    }
}
