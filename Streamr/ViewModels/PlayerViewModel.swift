import Foundation
import Combine
import AVFoundation
import SwiftData
import MediaPlayer

/// Manages playback of a single episode and persists the playback position.
@MainActor
final class PlayerViewModel: ObservableObject {

    // MARK: - Published state
    @Published var currentEpisode: Episode?
    @Published var isPlaying: Bool = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isLoading: Bool = false
    @Published var playbackRate: Float = 1.0

    // MARK: - Private
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var playerItemObserver: AnyCancellable?
    private var statusObserver: NSKeyValueObservation?
    private var durationObserver: NSKeyValueObservation?
    private var modelContext: ModelContext?

    /// How often (in seconds) the playback position is persisted to the model.
    private let persistenceInterval: Double = 5
    private var lastPersistTime: Double = -.infinity

    // MARK: - Setup

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
        setupAudioSession()
        setupRemoteCommandCenter()
    }

    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.allowBluetoothHFP, .allowAirPlay]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[PlayerViewModel] Audio session setup failed: \(error)")
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    @objc private func handleAudioSessionInterruption(_ notification: Notification) {
        guard
            let userInfo = notification.userInfo,
            let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        switch type {
        case .began:
            // iOS has already paused playback; update our state to match.
            if isPlaying {
                isPlaying = false
                updateNowPlayingPlaybackState()
                print("[PlayerViewModel] Audio session interruption began — playback paused")
            }

        case .ended:
            let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            print("[PlayerViewModel] Audio session interruption ended — shouldResume=\(options.contains(.shouldResume))")

            guard options.contains(.shouldResume) else { return }

            // Re-activate the session before resuming (required after some interruptions).
            try? AVAudioSession.sharedInstance().setActive(true)
            player?.play()
            if playbackRate != 1.0 { player?.rate = playbackRate }
            isPlaying = true
            updateNowPlayingPlaybackState()

        @unknown default:
            break
        }
    }

    // MARK: - Playback control

    func play(episode: Episode) {
        guard let url = episode.playbackURL else {
            print("[PlayerViewModel] play() aborted — no playbackURL for episode '\(episode.title)'")
            return
        }
        print("[PlayerViewModel] play() url=\(url) isDownloaded=\(episode.isDownloaded) localFilename=\(episode.localFilename ?? "nil")")

        // If we're already playing this episode, just resume.
        if currentEpisode?.id == episode.id {
            player?.play()
            isPlaying = true
            return
        }

        // Tear down the previous player.
        tearDown()

        currentEpisode = episode
        isLoading = true
        episode.lastPlayedAt = .now
        try? modelContext?.save()

        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)

        // Observe status
        let savedPosition = episode.playbackPosition
        statusObserver = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            let status = item.status
            let error = item.error
            Task { @MainActor [weak self] in
                guard let self else { return }
                print("[PlayerViewModel] item status=\(status.rawValue) error=\(error?.localizedDescription ?? "none")")
                if status == .readyToPlay {
                    self.isLoading = false
                    if savedPosition > 1 {
                        await self.player?.seek(to: CMTime(seconds: savedPosition, preferredTimescale: 600))
                    }
                    self.player?.play()
                    if self.playbackRate != 1.0 {
                        self.player?.rate = self.playbackRate
                    }
                    self.isPlaying = true
                    print("[PlayerViewModel] playback started, rate=\(self.player?.rate ?? 0)")
                } else if status == .failed {
                    print("[PlayerViewModel] item FAILED: \(error?.localizedDescription ?? "unknown")")
                    self.isLoading = false
                    self.isPlaying = false
                }
            }
        }

        // Observe duration
        durationObserver = item.observe(\.duration, options: [.new]) { [weak self] item, _ in
            let d = item.duration.seconds
            Task { @MainActor [weak self] in
                guard let self, d.isFinite, d > 0 else { return }
                self.duration = d
                self.currentEpisode?.duration = d
                try? self.modelContext?.save()
            }
        }

        // Periodic time observer — delivered on .main queue; assert MainActor isolation
        // to silence Sendable warnings without adding async Task overhead.
        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                let t = time.seconds
                guard t.isFinite else { return }
                self.currentTime = t
                self.currentEpisode?.playbackPosition = t

                if t - self.lastPersistTime >= self.persistenceInterval {
                    self.lastPersistTime = t
                    try? self.modelContext?.save()
                }
            }
        }

        // End of episode
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerDidFinish),
            name: .AVPlayerItemDidPlayToEndTime,
            object: item
        )

        updateNowPlaying(episode: episode)
    }

    func stop() {
        tearDown()
        currentEpisode = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        isLoading = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            persistCurrentPosition()
        } else {
            player.play()
            isPlaying = true
        }
        updateNowPlayingPlaybackState()
    }

    func seek(to seconds: Double) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        currentTime = seconds
        currentEpisode?.playbackPosition = seconds
        try? modelContext?.save()
    }

    func skip(by seconds: Double) {
        let target = min(max(0, currentTime + seconds), duration)
        seek(to: target)
    }

    func setRate(_ rate: Float) {
        playbackRate = rate
        if isPlaying { player?.rate = rate }
    }

    // MARK: - Finish

    @objc private func playerDidFinish() {
        isPlaying = false
        currentEpisode?.isFinished = true
        currentEpisode?.playbackPosition = 0
        try? modelContext?.save()
        updateNowPlayingPlaybackState()
        advanceToNextEpisode()
    }

    private func advanceToNextEpisode() {
        guard
            let finished = currentEpisode,
            let playlist = finished.playlist,
            let ctx = modelContext
        else { return }

        // Re-fetch all episodes in the playlist so we have a fresh, fully-sorted list.
        let playlistID = playlist.id
        let all = (try? ctx.fetch(FetchDescriptor<Episode>())) ?? []
        let queue = all
            .filter { $0.playlist?.id == playlistID && !$0.isFinished }
            .sorted { $0.queuePosition < $1.queuePosition }

        guard let next = queue.first else { return }
        play(episode: next)
    }

    private func persistCurrentPosition() {
        try? modelContext?.save()
    }

    private func tearDown() {
        if let obs = timeObserver, let player {
            player.removeTimeObserver(obs)
        }
        timeObserver = nil
        statusObserver = nil
        durationObserver = nil
        playerItemObserver = nil
        player?.pause()
        player = nil
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)
    }

    // MARK: - Now Playing / Lock Screen

    private func setupRemoteCommandCenter() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            self?.skip(by: -15)
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [30]
        center.skipForwardCommand.addTarget { [weak self] _ in
            self?.skip(by: 30)
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: e.positionTime)
            return .success
        }
    }

    private func updateNowPlaying(episode: Episode) {
        // Resolve the playlist name. The SwiftData back-relationship may not be
        // faulted in yet on the episode object itself, so try the model context
        // as a fallback to ensure we always get a value.
        let playlistName: String? = episode.playlist?.name ?? {
            guard let ctx = modelContext else { return nil }
            let all = (try? ctx.fetch(FetchDescriptor<Playlist>())) ?? []
            return all.first(where: { $0.episodes.contains(where: { $0.id == episode.id }) })?.name
        }()

        print("[PlayerViewModel] updateNowPlaying title='\(episode.title)' playlist='\(episode.playlist?.name ?? "nil")' resolved='\(playlistName ?? "nil")'")

        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = episode.title
        if let playlistName {
            info[MPMediaItemPropertyArtist] = playlistName
            info[MPMediaItemPropertyAlbumTitle] = playlistName
        }
        info[MPMediaItemPropertyMediaType] = MPMediaType.podcast.rawValue
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = episode.playbackPosition
        info[MPMediaItemPropertyPlaybackDuration] = episode.duration > 0 ? episode.duration : nil
        info[MPNowPlayingInfoPropertyPlaybackRate] = playbackRate
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        // Fetch artwork asynchronously and update Now Playing once it arrives.
        if let urlString = episode.pageIconURL, let url = URL(string: urlString) {
            Task {
                await fetchAndSetArtwork(from: url)
            }
        }
    }

    /// Downloads the image at `url` and injects it as `MPMediaItemPropertyArtwork`.
    private func fetchAndSetArtwork(from url: URL) async {
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data)
        else { return }

        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyArtwork] = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateNowPlayingPlaybackState() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? playbackRate : 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
