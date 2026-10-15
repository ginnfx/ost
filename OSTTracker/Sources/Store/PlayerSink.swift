// The audio sink. Python resolves what to play (yt-dlp) and owns canonical
// player state; this just points AVPlayer at the resolved stream URL and
// mirrors transport commands. No resolution logic lives here.

import AVFoundation
import Observation
#if os(iOS)
import MediaPlayer
#endif

@Observable
final class PlayerSink {
    static let volumeKey = "playerVolume"

    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var volume: Double = {
        let saved = UserDefaults.standard.object(forKey: "playerVolume") as? Double ?? 0.8
        return min(1, max(0, saved))
    }()
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
    var onFailed: (() -> Void)?
    #if os(iOS)
    var onRemotePlay: (() -> Void)?
    var onRemotePause: (() -> Void)?
    var onRemoteSeek: ((Double) -> Void)?
    private var remoteCommandsInstalled = false
    private var nowPlayingTitle = ""
    private var nowPlayingSource: String?
    #endif

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
            if let stream = routedStreamURL(state.streamUrl), let url = URL(string: stream),
               stream != currentStreamURL || player?.currentItem?.status == .failed {
                load(url, stream: stream)
            }
            #if os(iOS)
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default)
                try session.setActive(true)
            } catch {
                print("GATE audio session activation failed: \(error)")
            }
            #endif
            player?.play()
            #if os(iOS)
            updateNowPlayingInfo()
            #endif
        case .paused:
            player?.pause()
            #if os(iOS)
            updateNowPlayingInfo()
            #endif
        case .idle, .stopped:
            tearDown()
            #if os(iOS)
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
        }
    }

    private func routedStreamURL(_ stream: String?) -> String? {
        guard let stream else { return nil }
        #if os(iOS)
        guard var relay = URLComponents(string: stream),
              relay.host == "127.0.0.1" || relay.host == "localhost",
              let address = UserDefaults.standard.string(forKey: LANConnection.addressKey),
              let backend = URLComponents(string: address) else { return stream }
        relay.host = backend.host
        relay.port = backend.port
        return relay.url?.absoluteString ?? stream
        #else
        return stream
        #endif
    }

    func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        position = seconds
        positionUpdatedAt = CFAbsoluteTimeGetCurrent()
        #if os(iOS)
        updateNowPlayingInfo()
        #endif
    }

    func setVolume(_ value: Double) {
        volume = min(1, max(0, value))
        player?.volume = Float(volume)
        UserDefaults.standard.set(volume, forKey: Self.volumeKey)
    }

    /// Forces local teardown independent of server confirmation — used when
    /// the OST behind the current session is deleted and the server's own
    /// stop call may have failed or /ws may be down, which must not leave
    /// audio for a deleted OST still playing.
    func reset() {
        tearDown()
        #if os(iOS)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #endif
    }

    #if os(iOS)
    func setNowPlaying(title: String, source: String?) {
        nowPlayingTitle = title
        nowPlayingSource = source
        updateNowPlayingInfo()
    }

    func installRemoteCommands() {
        guard !remoteCommandsInstalled else { return }
        remoteCommandsInstalled = true
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.isEnabled = true
        commands.pauseCommand.isEnabled = true
        commands.togglePlayPauseCommand.isEnabled = true
        commands.changePlaybackPositionCommand.isEnabled = true
        commands.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onRemotePlay?() }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.onRemotePause?() }
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if (self.player?.rate ?? 0) > 0 { self.onRemotePause?() }
                else { self.onRemotePlay?() }
            }
            return .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let target = event.positionTime
            Task { @MainActor in self?.onRemoteSeek?(target) }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard !nowPlayingTitle.isEmpty else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: nowPlayingTitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, position),
            MPNowPlayingInfoPropertyPlaybackRate: player?.rate ?? 0,
        ]
        if let nowPlayingSource, !nowPlayingSource.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = nowPlayingSource
        }
        if duration.isFinite, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    #endif

    private var statusObservation: NSKeyValueObservation?

    private func load(_ url: URL, stream: String) {
        tearDown()
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.volume = Float(volume)
        self.player = player
        currentStreamURL = stream
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            let error = item.error.map(String.init(describing:)) ?? "none"
            print("GATE avplayer status=\(item.status.rawValue) error=\(error)")
            if item.status == .failed {
                Task { @MainActor [weak self] in
                    guard let self, self.player?.currentItem === item else { return }
                    self.onFailed?()
                }
            } else if item.status == .readyToPlay {
                Task { @MainActor [weak self] in
                    guard let self, self.player?.currentItem === item,
                          item.audioMix == nil else { return }
                    // A remote asset can expose its audio track only once the
                    // item is ready. Retry the tap after that transition.
                    self.attachSpectrumTap(to: item)
                }
            }
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
                #if os(iOS)
                self?.updateNowPlayingInfo()
                #endif
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
