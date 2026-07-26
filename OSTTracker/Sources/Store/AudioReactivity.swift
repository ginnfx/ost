// Per-frame envelope derivation over SpectrumEngine bands, plus the reusable
// music-pulse modifier every reactive surface uses. Same polled pattern as
// SpectrumView: a TimelineView leaf reads spectrum.snapshot() at display rate;
// nothing here ever touches @Observable state, so reactivity never invalidates
// anything beyond the leaf it's applied to.

import SwiftUI

/// View-ready energy levels derived from one 24-band snapshot.
struct AudioEnvelopes {
    var bass: Double = 0    // low bands: backdrop swell, card pulse, cover thump
    var mids: Double = 0
    var highs: Double = 0
    var kick: Double = 0    // bass onset transient: wordmark bounce
    var isActive: Bool = false
}

/// Stateful tracker — kick detection needs frame-to-frame memory. Plain class,
/// deliberately NOT observable: mutating it inside a TimelineView closure must
/// never schedule another render.
final class AudioPulse {
    private var bassBaseline: Double = 0
    private var kickEnvelope: Double = 0

    func update(bands: [Float]) -> AudioEnvelopes {
        guard bands.count == SpectrumEngine.bandCount else { return AudioEnvelopes() }

        func mean(_ range: Range<Int>) -> Double {
            range.reduce(0.0) { $0 + Double(bands[$1]) } / Double(range.count)
        }
        let bass = mean(0..<5)
        let mids = mean(5..<14)
        let highs = mean(14..<24)

        // Kick = bass rising above its own slow-moving baseline. The baseline
        // EMA spans ~0.5s at display rate; the envelope snaps up on onsets and
        // decays fast so the bounce reads as a hit, not a wobble.
        bassBaseline = bassBaseline * 0.97 + bass * 0.03
        let onset = max(0, bass - bassBaseline - 0.03)
        kickEnvelope = max(kickEnvelope * 0.82, min(1, onset * 5))

        return AudioEnvelopes(
            bass: bass, mids: mids, highs: highs, kick: kickEnvelope,
            isActive: bass + mids + highs > 0.02
        )
    }
}

/// Scales content with a chosen envelope while music plays; renders exactly the
/// static look when paused (envelopes zero out, scale returns to 1).
struct MusicPulseModifier: ViewModifier {
    let spectrum: SpectrumEngine
    let isPlaying: Bool
    var amount: CGFloat
    var driver: KeyPath<AudioEnvelopes, Double> = \.bass
    var anchor: UnitPoint = .center

    @State private var pulse = AudioPulse()
    // HIG: Reduce Motion disables ambient/looping animation entirely.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(Theme.fxDefaultsKey) private var fxEnabled = true

    func body(content: Content) -> some View {
        // 20fps: each ticking TimelineView schedules a full ViewGraph render
        // transaction (confirmed by sampling) — small-amplitude ambience can't
        // justify more. The sparkles toggle kills it entirely.
        let active = isPlaying && !reduceMotion && fxEnabled
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !active)) { _ in
            let env = active ? pulse.update(bands: spectrum.snapshot()) : AudioEnvelopes()
            content.scaleEffect(1 + CGFloat(env[keyPath: driver]) * amount, anchor: anchor)
        }
    }
}

extension View {
    func musicPulse(
        spectrum: SpectrumEngine,
        isPlaying: Bool,
        amount: CGFloat,
        driver: KeyPath<AudioEnvelopes, Double> = \.bass,
        anchor: UnitPoint = .center
    ) -> some View {
        modifier(MusicPulseModifier(
            spectrum: spectrum, isPlaying: isPlaying,
            amount: amount, driver: driver, anchor: anchor
        ))
    }

    /// Attaches the pulse only while `active`. Used on roster cards so a 50-card
    /// grid doesn't carry 50 AudioPulse/TimelineView nodes for an effect only the
    /// single playing card ever uses.
    @ViewBuilder
    func musicPulse(
        onlyWhen active: Bool,
        spectrum: SpectrumEngine,
        amount: CGFloat,
        driver: KeyPath<AudioEnvelopes, Double> = \.bass,
        anchor: UnitPoint = .center
    ) -> some View {
        if active {
            musicPulse(spectrum: spectrum, isPlaying: true, amount: amount, driver: driver, anchor: anchor)
        } else {
            self
        }
    }
}
