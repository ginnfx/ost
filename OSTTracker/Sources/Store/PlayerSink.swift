// The audio sink. Python resolves what to play (yt-dlp) and owns canonical
// player state; this just points AVPlayer at the resolved stream URL and
// mirrors transport commands. No resolution logic lives here.

import AVFoundation
import Observation

@Observable
final class PlayerSink {
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    /// Wall-clock stamp of the last position tick (0.5s cadence). Lets the
    /// lyrics view interpolate between ticks instead of quantizing line
    /// changes to half-second steps. Not observable on purpose.
    @ObservationIgnored private(set) var positionUpdatedAt: CFAbsoluteTime = 0

    /// Live FFT bands for the visualizer. Not @Observable state — the UI polls
    /// it at display rate (see SpectrumEngine).
    @ObservationIgnored let spectrum = SpectrumEngine()

    /// Called on the main actor when the current item plays to its natural end.
    /// The store uses this to tell Python to leave the `.playing` state — without
    /// it a finished track stays `status == "playing"` forever and every
    /// audio-reactive animation keeps compositing on silence (idle-heat bug).
    var onEnded: (() -> Void)?

    private var player: AVPlayer?
    private var currentStreamURL: String?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var tapAttachTask: Task<Void, Never>?

    func apply(_ state: PlaybackState) {
        switch state.status {
        case .resolving:
            break
        case .playing:
            if let stream = state.streamUrl, let url = URL(string: stream),
               stream != currentStreamURL || player?.currentItem?.status == .failed {
                load(url, stream: stream)
            }
            player?.play()
        case .paused:
            player?.pause()
        case .idle, .stopped:
            tearDown()
        }
    }

    func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    /// Forces local teardown independent of server confirmation — used when
    /// the OST behind the current session is deleted and the server's own
    /// stop call may have failed or /ws may be down, which must not leave
    /// audio for a deleted OST still playing.
    func reset() {
        tearDown()
    }

    private var statusObservation: NSKeyValueObservation?

    private func load(_ url: URL, stream: String) {
        tearDown()
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        currentStreamURL = stream
        statusObservation = item.observe(\.status) { item, _ in
            let error = item.error.map(String.init(describing:)) ?? "none"
            print("GATE avplayer status=\(item.status.rawValue) error=\(error)")
        }
        attachSpectrumTap(to: item)
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEnded?() }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.position = time.seconds
                self?.positionUpdatedAt = CFAbsoluteTimeGetCurrent()
                if let item = self?.player?.currentItem, item.duration.isNumeric {
                    self?.duration = item.duration.seconds
                }
            }
        }
    }

    /// Audio tracks of a remote item load asynchronously, so the tap has to be
    /// attached once they arrive. Failure at any step just means no visualizer
    /// data — playback itself is untouched.
    private func attachSpectrumTap(to item: AVPlayerItem) {
        tapAttachTask?.cancel()
        tapAttachTask = Task { [weak self, weak item] in
            guard let asset = item?.asset,
                  let tracks = try? await asset.loadTracks(withMediaType: .audio),
                  let track = tracks.first,
                  !Task.isCancelled,
                  let tap = self?.spectrum.makeTap()
            else { return }
            let params = AVMutableAudioMixInputParameters(track: track)
            params.audioTapProcessor = tap
            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            item?.audioMix = mix
        }
    }

    private func tearDown() {
        tapAttachTask?.cancel()
        tapAttachTask = nil
        player?.currentItem?.audioMix = nil
        if let observer = timeObserver { player?.removeTimeObserver(observer) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player?.pause()
        player = nil
        currentStreamURL = nil
        position = 0
        duration = 0
    }
}
