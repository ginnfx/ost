// Live frequency bands from whatever AVPlayer is playing. An
// MTAudioProcessingTap on the player item's audio track hands us the decoded
// PCM mid-flight; vDSP FFTs it into log-spaced bands the visualizer polls.
// The tap process callback runs on the realtime audio thread, so everything it
// touches is preallocated and the shared-state critical section is tiny.

import Accelerate
import AVFoundation

/// Polled (not observed) on purpose: the UI reads bands at display rate via
/// TimelineView; pushing 60Hz updates through @Observable would re-render far
/// more than the one Canvas that cares.
///
/// `nonisolated` is critical: the project compiles with
/// SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor, and an implicitly-MainActor engine
/// puts a main-thread assertion inside consume()/prepared() — which the tap
/// invokes from the realtime audio thread → instant SIGTRAP on first buffer.
nonisolated final class SpectrumEngine: @unchecked Sendable {
    static let bandCount = 24

    private let lock = NSLock()
    private var bands = [Float](repeating: 0, count: SpectrumEngine.bandCount)
    private var lastUpdate: CFAbsoluteTime = 0

    // MARK: FFT scratch (touched only from the single tap process thread)

    private let fftSize = 1024
    private let log2n: vDSP_Length
    // nonisolated(unsafe): OpaquePointer isn't Sendable, so a plain `let` can't
    // be touched from deinit under strict concurrency. Safe: created in init,
    // used only on the single tap process thread, destroyed in deinit.
    private nonisolated(unsafe) let fftSetup: FFTSetup
    private var hannWindow: [Float]
    private var windowed: [Float]
    private var realPart: [Float]
    private var imagPart: [Float]
    private var magnitudes: [Float]
    private var sampleRate: Double = 44100
    private var isNonInterleaved = true
    private var channelCount = 2
    private var bandBinRanges: [Range<Int>] = []

    init() {
        log2n = vDSP_Length(log2(Float(fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        hannWindow = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&hannWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        windowed = [Float](repeating: 0, count: fftSize)
        realPart = [Float](repeating: 0, count: fftSize / 2)
        imagPart = [Float](repeating: 0, count: fftSize / 2)
        magnitudes = [Float](repeating: 0, count: fftSize / 2)
        rebuildBandRanges()
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    /// Log-spaced band edges 40Hz–14kHz mapped to FFT bins for the current
    /// sample rate. Every band keeps at least one bin.
    private func rebuildBandRanges() {
        let nyquist = sampleRate / 2
        let binHz = nyquist / Double(fftSize / 2)
        let low = 40.0, high = min(14000.0, nyquist - binHz)
        var ranges: [Range<Int>] = []
        for band in 0..<Self.bandCount {
            let f0 = low * pow(high / low, Double(band) / Double(Self.bandCount))
            let f1 = low * pow(high / low, Double(band + 1) / Double(Self.bandCount))
            let b0 = max(1, Int(f0 / binHz))
            let b1 = max(b0 + 1, min(fftSize / 2, Int(f1 / binHz)))
            ranges.append(b0..<b1)
        }
        bandBinRanges = ranges
    }

    // MARK: Tap lifecycle (called from the tap C callbacks)

    fileprivate func prepared(format: AudioStreamBasicDescription) {
        sampleRate = format.mSampleRate
        isNonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        channelCount = Int(format.mChannelsPerFrame)
        rebuildBandRanges()
    }

    fileprivate func consume(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        guard frameCount > 0 else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        guard let first = buffers.first, let data = first.mData else { return }
        let stride = isNonInterleaved ? 1 : max(1, channelCount)
        let available = Int(first.mDataByteSize) / MemoryLayout<Float>.size / stride
        let samples = data.assumingMemoryBound(to: Float.self)
        let count = min(fftSize, min(frameCount, available))

        // Window into the preallocated buffer (zero-padded when short).
        if stride == 1 {
            vDSP_vmul(samples, 1, hannWindow, 1, &windowed, 1, vDSP_Length(count))
        } else {
            vDSP_vmul(samples, vDSP_Stride(stride), hannWindow, 1, &windowed, 1, vDSP_Length(count))
        }
        if count < fftSize {
            vDSP_vclr(&windowed[count], 1, vDSP_Length(fftSize - count))
        }

        var newBands = [Float](repeating: 0, count: Self.bandCount)
        realPart.withUnsafeMutableBufferPointer { real in
            imagPart.withUnsafeMutableBufferPointer { imag in
                var split = DSPSplitComplex(realp: real.baseAddress!, imagp: imag.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    vDSP_ctoz(
                        raw.bindMemory(to: DSPComplex.self).baseAddress!, 2,
                        &split, 1, vDSP_Length(fftSize / 2)
                    )
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
            }
        }
        var scale = Float(1.0 / Float(fftSize))
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(fftSize / 2))
        for (i, range) in bandBinRanges.enumerated() {
            var mean: Float = 0
            magnitudes.withUnsafeBufferPointer { mags in
                vDSP_meanv(mags.baseAddress! + range.lowerBound, 1, &mean, vDSP_Length(range.count))
            }
            // -55dB..-8dB -> 0..1 reads lively without pinning quiet passages to zero.
            let db = 20 * log10(mean + 1e-9)
            newBands[i] = max(0, min(1, (db + 55) / 47))
        }

        lock.lock()
        for i in 0..<Self.bandCount {
            let old = bands[i]
            // Fast attack, slower release — bars snap up and fall smoothly.
            bands[i] = newBands[i] > old ? old * 0.35 + newBands[i] * 0.65
                                         : old * 0.80 + newBands[i] * 0.20
        }
        lastUpdate = CFAbsoluteTimeGetCurrent()
        lock.unlock()
    }

    /// Current bands with a stateless decay: once fresh data stops arriving
    /// (pause/stop/teardown) the bars melt to the floor instead of freezing.
    func snapshot(at now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> [Float] {
        lock.lock()
        let copy = bands
        let age = now - lastUpdate
        lock.unlock()
        guard lastUpdate > 0 else { return [Float](repeating: 0, count: Self.bandCount) }
        let decay = Float(exp(-4 * max(0, age - 0.12)))
        return decay >= 0.999 ? copy : copy.map { $0 * decay }
    }

    /// A retained tap ready to drop into AVMutableAudioMixInputParameters, or
    /// nil if creation fails (visualizer degrades, playback unaffected).
    func makeTap() -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            // Unretained: the engine is owned by PlayerSink for the app's whole
            // lifetime, and a retain here would cycle through the audio mix.
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            init: { _, clientInfo, tapStorageOut in tapStorageOut.pointee = clientInfo },
            finalize: { _ in },
            prepare: { tap, _, formatPointer in
                engine(for: tap).prepared(format: formatPointer.pointee)
            },
            unprepare: { _ in },
            process: { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
                var sourceFlags = MTAudioProcessingTapFlags()
                var sourceFrames: CMItemCount = 0
                let status = MTAudioProcessingTapGetSourceAudio(
                    tap, numberFrames, bufferListInOut, &sourceFlags, nil, &sourceFrames
                )
                numberFramesOut.pointee = sourceFrames
                flagsOut.pointee = sourceFlags
                guard status == noErr else { return }
                engine(for: tap).consume(bufferListInOut, frameCount: Int(sourceFrames))
            }
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects, &tap
        )
        guard status == noErr, let tap else {
            print("SPECTRUM tap creation failed: \(status)")
            return nil
        }
        return tap
    }
}

private nonisolated func engine(for tap: MTAudioProcessingTap) -> SpectrumEngine {
    Unmanaged<SpectrumEngine>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
}
