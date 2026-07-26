// UI sound engine. Every sound is synthesized on first use into an
// AVAudioPCMBuffer (no bundled assets) and played through a small pool of
// player nodes on a dedicated AVAudioEngine — fully separate from the AVPlayer
// music path and mixed quiet so UI feedback never fights an OST. Mute persists
// via UserDefaults ("uiSoundsMuted"), toggled from the header speaker button.

import AVFoundation

enum UISound: Hashable {
    case hoverTick, select, dismiss, tabSwitch
    case playStart, pause, stop
    case resort, added
    case rate(Int)      // 0...10 — pitch rises with the score
    case rateCleared
    case navMove        // keyboard cursor step on the roster grid
    case navBump        // clamped edge hit — distinct low thud
}

final class SoundKit {
    static let shared = SoundKit()

    static let mutedDefaultsKey = "uiSoundsMuted"
    private static let sampleRate = 44100.0
    private static let poolSize = 6
    private static let hoverThrottle: CFAbsoluteTime = 0.06

    private let engine = AVAudioEngine()
    private let players: [AVAudioPlayerNode]
    private let format: AVAudioFormat
    private var buffers: [UISound: AVAudioPCMBuffer] = [:]
    private var nextPlayer = 0
    private var lastHoverAt: CFAbsoluteTime = 0
    private var idleStopTask: Task<Void, Never>?
    private static let idleStopDelay: Duration = .seconds(3)

    private init() {
        format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1)!
        players = (0..<Self.poolSize).map { _ in AVAudioPlayerNode() }
        for player in players {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
        }
        engine.mainMixerNode.outputVolume = Theme.uiSoundVolume
    }

    func play(_ sound: UISound) {
        guard !UserDefaults.standard.bool(forKey: Self.mutedDefaultsKey) else { return }
        if sound == .hoverTick {
            let now = CFAbsoluteTimeGetCurrent()
            guard now - lastHoverAt >= Self.hoverThrottle else { return }
            lastHoverAt = now
        }
        if !engine.isRunning {
            do { try engine.start() } catch {
                print("SOUND engine start failed: \(error)")
                return
            }
        }
        guard let buffer = buffer(for: sound) else { return }
        let player = players[nextPlayer]
        nextPlayer = (nextPlayer + 1) % players.count
        player.stop()
        player.scheduleBuffer(buffer)
        player.play()
        scheduleIdleStop()
    }

    /// Stop the audio engine after a few seconds without a new UI sound. Left
    /// running, AVAudioEngine holds the CoreAudio render thread active forever
    /// and keeps the CPU out of deep idle; it restarts lazily on the next sound.
    private func scheduleIdleStop() {
        idleStopTask?.cancel()
        idleStopTask = Task { [weak self] in
            try? await Task.sleep(for: Self.idleStopDelay)
            guard let self, !Task.isCancelled else { return }
            if self.players.allSatisfy({ !$0.isPlaying }) {
                self.engine.stop()
            }
        }
    }

    func play(rating score: Double?) {
        // Fractional scores share the nearest whole score's tone.
        play(score.map { UISound.rate(Int($0.rounded())) } ?? .rateCleared)
    }

    // MARK: - Synthesis

    private func buffer(for sound: UISound) -> AVAudioPCMBuffer? {
        if let cached = buffers[sound] { return cached }
        let rendered = render(sound)
        buffers[sound] = rendered
        return rendered
    }

    /// Each sound is a tiny additive score: (startTime, duration, startHz,
    /// endHz, gain) voices, sine with exponential pitch glide + decay.
    private func render(_ sound: UISound) -> AVAudioPCMBuffer? {
        switch sound {
        case .hoverTick:
            return tone([(0, 0.035, 1800, 1300, 0.22)])
        case .navMove:
            return tone([(0, 0.04, 900, 1100, 0.4)])
        case .navBump:
            return tone([(0, 0.06, 150, 110, 0.85)])
        case .select:
            return tone([(0, 0.10, 520, 920, 0.65)])
        case .dismiss:
            return tone([(0, 0.10, 920, 520, 0.55)])
        case .tabSwitch:
            return tone([(0, 0.06, 260, 210, 0.85)])
        case .playStart:
            return tone([(0, 0.07, 660, 660, 0.6), (0.075, 0.11, 990, 990, 0.6)])
        case .pause:
            return tone([(0, 0.08, 550, 500, 0.6)])
        case .stop:
            return tone([(0, 0.13, 440, 220, 0.55)])
        case .added:
            // Confirmation ding: fundamental + soft octave partial, long decay.
            return tone([(0, 0.45, 880, 880, 0.5), (0, 0.35, 1760, 1760, 0.18)])
        case .rateCleared:
            return tone([(0, 0.10, 400, 260, 0.45)])
        case .rate(let score):
            return ratingTone(score: score)
        case .resort:
            return whoosh(duration: 0.28, gain: 0.5)
        }
    }

    private func ratingTone(score: Int) -> AVAudioPCMBuffer? {
        let clamped = max(0, min(10, score))
        // One octave of range: score 0 = 330Hz, score 10 = 660Hz.
        let base = 330 * pow(2, Double(clamped) / 10)
        switch clamped {
        case 0:
            // The sad low womp.
            return tone([(0, 0.22, 240, 130, 0.6)])
        case 10:
            // Triumphant major arpeggio off the top pitch.
            return tone([
                (0, 0.09, base, base, 0.55),
                (0.08, 0.09, base * 1.25, base * 1.25, 0.55),
                (0.16, 0.18, base * 1.5, base * 1.5, 0.6),
            ])
        default:
            return tone([(0, 0.12, base * 0.97, base, 0.55)])
        }
    }

    private typealias Voice = (start: Double, duration: Double, fromHz: Double, toHz: Double, gain: Double)

    private func tone(_ voices: [Voice]) -> AVAudioPCMBuffer? {
        let total = voices.map { $0.start + $0.duration }.max() ?? 0
        return fill(duration: total) { samples, sampleRate in
            for voice in voices {
                let startFrame = Int(voice.start * sampleRate)
                let frames = Int(voice.duration * sampleRate)
                var phase = 0.0
                for i in 0..<frames where startFrame + i < samples.count {
                    let t = Double(i) / Double(frames)
                    // Exponential pitch glide; phase accumulated so glides are
                    // click-free.
                    let hz = voice.fromHz * pow(voice.toHz / voice.fromHz, t)
                    phase += 2 * .pi * hz / sampleRate
                    // 2ms attack ramp, then exponential decay.
                    let attack = min(1, Double(i) / (0.002 * sampleRate))
                    let decay = exp(-4.5 * t)
                    samples[startFrame + i] += Float(sin(phase) * attack * decay * voice.gain)
                }
            }
        }
    }

    private func whoosh(duration: Double, gain: Double) -> AVAudioPCMBuffer? {
        fill(duration: duration) { samples, sampleRate in
            var lowpassed = 0.0
            var seed: UInt64 = 0x9E3779B97F4A7C15
            for i in 0..<samples.count {
                let t = Double(i) / Double(samples.count)
                // xorshift noise — deterministic, no Foundation RNG in the loop.
                seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
                let noise = Double(Int64(bitPattern: seed)) / Double(Int64.max)
                // One-pole lowpass whose cutoff sweeps up then down with the
                // sin² amplitude envelope — reads as air moving past.
                let sweep = 0.04 + 0.25 * sin(t * .pi)
                lowpassed += (noise - lowpassed) * sweep
                let envelope = sin(t * .pi) * sin(t * .pi)
                samples[i] += Float(lowpassed * envelope * gain * 2.2)
            }
        }
    }

    private func fill(
        duration: Double,
        render: (_ samples: UnsafeMutableBufferPointer<Float>, _ sampleRate: Double) -> Void
    ) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(duration * Self.sampleRate)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = frames
        let samples = UnsafeMutableBufferPointer(start: channel, count: Int(frames))
        for i in samples.indices { samples[i] = 0 }
        render(samples, Self.sampleRate)
        // Hard 5ms fade-out guard so no voice ends on a click.
        let fade = min(Int(0.005 * Self.sampleRate), samples.count)
        for i in 0..<fade {
            samples[samples.count - 1 - i] *= Float(i) / Float(fade)
        }
        return buffer
    }
}
