import AVFoundation
import MediaPlayer
import Observation
import UIKit

/// Wiedergabe-Kern (Apple: `MTPlayerController`, `IMAVPlayer`, `MTMediaRemoteController`)
@MainActor @Observable
final class PlayerController {
    enum SleepTimer: Equatable {
        case off
        case until(Date)
        case endOfEpisode
        case endOfChapter
    }

    static let speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 3]

    private(set) var episode: Episode?
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var rate: Double = 1
    /// Tempo gilt eigens für diese Sendung (PinePods `podcast/set_playback_speed`)
    private(set) var rateIsCustomForShow = false
    private(set) var chapters: [Chapter] = []
    private(set) var sleepTimer: SleepTimer = .off
    private(set) var errorMessage: String?
    /// Bei Folgen aus einer Vorschau: Kapitel-URL aus dem Feed
    var feedChapterURL: URL?

    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var statusObs: NSKeyValueObservation?
    @ObservationIgnored private var bufferObs: NSKeyValueObservation?
    @ObservationIgnored private var lastReport: Date = .distantPast
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    @ObservationIgnored private var artwork: MPMediaItemArtwork?
    @ObservationIgnored weak var library: LibraryStore?
    @ObservationIgnored var downloads: DownloadManager { .shared }
    @ObservationIgnored private var defaultRate: Double = 1

    init() {
        player.allowsExternalPlayback = true
        player.automaticallyWaitsToMinimizeStalling = true
        configureSession()
        configureRemote()
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let opts = (n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init) ?? []
            MainActor.assumeIsolated {
                if type == .began { self?.pause() } else if type == .ended, opts.contains(.shouldResume) { self?.resume() }
            }
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in
            // Kopfhörer abgezogen → anhalten (wie Apple)
            let reason = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            MainActor.assumeIsolated { if reason == .oldDeviceUnavailable { self?.pause() } }
        }
    }

    private func configureSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
    }

    var currentChapter: Chapter? { chapters.last { $0.start <= currentTime + 0.5 } }
    var currentChapterIndex: Int? { currentChapter.flatMap { c in chapters.firstIndex(of: c) } }

    // MARK: Abspielen

    /// Folge abspielen. Startposition: lokal nicht gesendete Position, sonst Serverstand.
    func play(_ e: Episode, at start: TimeInterval? = nil, chapterURL: URL? = nil) {
        if episode?.id == e.id, start == nil {
            if !isPlaying { resume() }
            return
        }
        saveProgress(force: true)
        let ep = library?.current(e) ?? e
        episode = ep
        feedChapterURL = chapterURL
        chapters = []
        errorMessage = nil
        duration = ep.duration
        currentTime = start ?? (ep.completed ? 0 : (library?.pendingPosition(ep) ?? ep.position))
        artwork = nil
        let url = downloads.localURL(ep) ?? ep.audioURL
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        item.audioTimePitchAlgorithm = .timeDomain
        observe(item)
        player.replaceCurrentItem(with: item)
        try? AVAudioSession.sharedInstance().setActive(true)
        if currentTime > 1 { player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600)) }
        if ep.queued { library?.removeFromQueue(ep) }
        resume()
        updateNowPlaying()
        Task { await loadExtras(for: ep, explicitStart: start != nil) }
    }

    /// Außerhalb des MainActors gebaut: iOS ruft den Block auf einem Hintergrund-Thread auf
    /// (sonst Absturz in der Swift-6-Isolationsprüfung, sobald der Sperrbildschirm das Cover holt).
    nonisolated private static func makeArtwork(_ img: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: img.size) { _ in img }
    }

    /// Kapitel, Server-Position und Tempo nachladen
    private func loadExtras(for ep: Episode, explicitStart: Bool) async {
        if let url = ep.artworkURL, let img = await ImageLoader.shared.image(url) {
            artwork = Self.makeArtwork(img)
            updateNowPlaying()
        }
        if let client = library?.client, let id = ep.serverID {
            // neuere Position vom Server (anderes Gerät) übernehmen, wenn lokal nichts aussteht
            if !explicitStart, library?.pendingPosition(ep) == nil, let meta = try? await client.episodeMetadata(id),
               episode?.id == ep.id, !meta.completed, abs(meta.position - currentTime) > 15, currentTime < meta.position || currentTime < 20 {
                seek(to: meta.position)
            }
            if let sid = ep.showServerID, let d = try? await client.playDetails(podcastID: sid), episode?.id == ep.id {
                defaultRate = (try? await client.playbackSpeed(podcastID: nil)) ?? 1
                rateIsCustomForShow = d.customized
                setRate(d.speed, persist: false)
            }
            if let ch = try? await client.chapters(episodeID: id), !ch.isEmpty, episode?.id == ep.id { chapters = ch }
        }
        if chapters.isEmpty, let u = feedChapterURL, let ch = try? await ChapterJSON.load(u), episode?.id == ep.id { chapters = ch }
        if chapters.isEmpty { chapters = await Self.fileChapters(downloads.localURL(ep) ?? ep.audioURL) }
        updateNowPlaying()
    }

    /// Kapitel aus der Datei (ID3 CHAP / MP4-Kapitel)
    nonisolated static func fileChapters(_ url: URL) async -> [Chapter] {
        let asset = AVURLAsset(url: url)
        guard let locales = try? await asset.load(.availableChapterLocales), !locales.isEmpty else { return [] }
        guard let groups = try? await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: Locale.preferredLanguages) else { return [] }
        var out: [Chapter] = []
        for (i, g) in groups.enumerated() {
            let title = (try? await AVMetadataItem.metadataItems(from: g.items, filteredByIdentifier: .commonIdentifierTitle).first?.load(.stringValue)) ?? nil
            out.append(Chapter(start: g.timeRange.start.seconds, title: title ?? String(localized: "Kapitel \(i + 1)")))
        }
        return out
    }

    #if DEBUG
    /// Nur für Screenshots mit Demodaten: Player-Zustand setzen, ohne etwas zu laden
    func showDemo(_ e: Episode, chapters: [Chapter]) {
        episode = e
        duration = e.duration
        currentTime = e.position
        self.chapters = chapters
        isPlaying = true
        rate = 1.25
    }
    #endif

    func togglePlay() { isPlaying ? pause() : resume() }

    func resume() {
        guard player.currentItem != nil else {
            if let e = episode { let ep = e; episode = nil; play(ep) }
            return
        }
        player.playImmediately(atRate: Float(rate))
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        player.pause()
        isPlaying = false
        saveProgress(force: true)
        updateNowPlaying()
    }

    func stop() {
        pause()
        player.replaceCurrentItem(with: nil)
        episode = nil
        chapters = []
        cancelSleepTimer()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func seek(to t: TimeInterval) {
        let target = max(0, min(t, duration > 0 ? duration - 0.5 : t))
        currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        updateNowPlaying()
    }

    func skipForward() { seek(to: currentTime + Double(AppSettings.shared.skipForward)) }
    func skipBackward() { seek(to: currentTime - Double(AppSettings.shared.skipBackward)) }

    func nextChapter() {
        guard let i = currentChapterIndex, i + 1 < chapters.count else { return }
        seek(to: chapters[i + 1].start)
    }

    func previousChapter() {
        guard let i = currentChapterIndex else { return }
        // wie Apple: innerhalb der ersten 3 s an den Anfang des vorigen Kapitels, sonst an den Anfang des aktuellen
        if currentTime - chapters[i].start < 3, i > 0 { seek(to: chapters[i - 1].start) } else { seek(to: chapters[i].start) }
    }

    /// Nächste Folge aus der Warteliste
    func playNext() {
        guard let next = library?.popQueue(after: episode) else { return }
        play(next)
    }

    // MARK: Tempo

    func setRate(_ r: Double, persist: Bool = true) {
        rate = r
        if isPlaying { player.rate = Float(r) }
        updateNowPlaying()
        guard persist, let client = library?.client else { return }
        Task {
            if rateIsCustomForShow, let sid = episode?.showServerID { try? await client.setShowSpeed(r, podcastID: sid) }
            else { try? await client.setDefaultSpeed(r); defaultRate = r }
        }
    }

    /// „Eigens für diese Sendung“ an/aus
    func setRateCustomForShow(_ on: Bool) {
        rateIsCustomForShow = on
        guard let client = library?.client, let sid = episode?.showServerID else { return }
        let r = rate
        Task {
            if on { try? await client.setShowSpeed(r, podcastID: sid) }
            else { try? await client.setShowSpeed(nil, podcastID: sid); setRate(defaultRate, persist: false) }
        }
    }

    // MARK: Schlaf-Timer

    func setSleepTimer(_ t: SleepTimer) {
        cancelSleepTimer()
        sleepTimer = t
        guard case .until(let date) = t else { return }
        sleepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                let left = date.timeIntervalSinceNow
                if left <= 10 { self.player.volume = Float(max(0, left / 10)) } // langsam ausblenden
                if left <= 0 { self.fireSleep(); return }
            }
        }
    }

    func setSleepMinutes(_ m: Int) { setSleepTimer(.until(.now.addingTimeInterval(TimeInterval(m * 60)))) }

    func cancelSleepTimer() {
        sleepTask?.cancel(); sleepTask = nil
        sleepTimer = .off
        player.volume = 1
    }

    var sleepRemaining: TimeInterval? {
        if case .until(let d) = sleepTimer { return max(0, d.timeIntervalSinceNow) }
        return nil
    }

    private func fireSleep() {
        pause()
        cancelSleepTimer()
    }

    // MARK: Fortschritt

    private func tick(_ t: TimeInterval) {
        guard t.isFinite, player.currentItem != nil else { return }
        let before = currentChapter
        currentTime = t
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0, abs(d - duration) > 1 { duration = d }
        if isPlaying, Date.now.timeIntervalSince(lastReport) >= 15 { saveProgress(force: true) }
        if sleepTimer == .endOfChapter, let b = before, currentChapter != b { fireSleep() }
        if before != currentChapter { updateNowPlaying() }
    }

    /// Position an Mediathek/Server melden (alle 15 s, beim Anhalten, Folgenwechsel, Hintergrund)
    func saveProgress(force: Bool = false) {
        guard let e = episode, currentTime > 0 else { return }
        lastReport = .now
        library?.reportPosition(e, position: currentTime, duration: duration)
    }

    private func observe(_ item: AVPlayerItem) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didFinish() }
        }
        // KVO meldet auf beliebigen Threads: Beobachter außerhalb des MainActors erzeugen (sonst Isolations-Absturz)
        statusObs = Self.observeStatus(item) { [weak self] failed, msg in if failed { self?.errorMessage = msg; self?.isPlaying = false } }
        bufferObs = Self.observeBuffering(player) { [weak self] waiting in self?.isBuffering = waiting }
    }

    nonisolated private static func observeStatus(_ item: AVPlayerItem, _ apply: @escaping @MainActor (Bool, String?) -> Void) -> NSKeyValueObservation {
        item.observe(\.status) { it, _ in
            let failed = it.status == .failed
            let msg = it.error?.localizedDescription
            Task { @MainActor in apply(failed, msg) }
        }
    }

    nonisolated private static func observeBuffering(_ player: AVPlayer, _ apply: @escaping @MainActor (Bool) -> Void) -> NSKeyValueObservation {
        player.observe(\.timeControlStatus) { p, _ in
            let waiting = p.timeControlStatus == .waitingToPlayAtSpecifiedRate
            Task { @MainActor in apply(waiting) }
        }
    }

    private func didFinish() {
        guard let e = episode else { return }
        library?.setCompleted(e, true)
        downloads.markPlayed(e)
        if sleepTimer == .endOfEpisode { cancelSleepTimer(); isPlaying = false; currentTime = 0; updateNowPlaying(); return }
        if AppSettings.shared.continuousPlayback, let next = library?.popQueue(after: e) {
            play(next)
        } else {
            isPlaying = false
            updateNowPlaying()
        }
    }

    // MARK: Sperrbildschirm / Kontrollzentrum

    private func updateNowPlaying() {
        guard let e = episode else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: currentChapter.map { "\($0.title)" } ?? e.title,
            MPMediaItemPropertyArtist: currentChapter != nil ? e.title : e.showTitle,
            MPMediaItemPropertyAlbumTitle: e.showTitle,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: rate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPMediaItemPropertyMediaType: MPMediaType.podcast.rawValue,
        ]
        if let i = currentChapterIndex {
            info[MPNowPlayingInfoPropertyChapterNumber] = i
            info[MPNowPlayingInfoPropertyChapterCount] = chapters.count
        }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        applyRemoteMode()
    }

    private func configureRemote() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.resume() }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.pause() }; return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.togglePlay() }; return .success }
        c.skipForwardCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.skipForward() }; return .success }
        c.skipBackwardCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.skipBackward() }; return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] ev in
            guard let ev = ev as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let t = ev.positionTime
            MainActor.assumeIsolated { self?.seek(to: t) }
            return .success
        }
        c.changePlaybackRateCommand.supportedPlaybackRates = Self.speeds.map { NSNumber(value: $0) }
        c.changePlaybackRateCommand.addTarget { [weak self] ev in
            guard let ev = ev as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            let r = Double(ev.playbackRate)
            MainActor.assumeIsolated { self?.setRate(r) }
            return .success
        }
        // Weiter/Zurück: erst Kapitel, dann nächste Folge (Einstellung „Externe Steuerelemente“)
        c.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let i = self.currentChapterIndex, i + 1 < self.chapters.count { self.nextChapter() } else { self.playNext() }
            }
            return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.currentChapterIndex != nil { self.previousChapter() } else { self.seek(to: 0) }
            }
            return .success
        }
    }

    private func applyRemoteMode() {
        let c = MPRemoteCommandCenter.shared()
        c.skipForwardCommand.preferredIntervals = [NSNumber(value: AppSettings.shared.skipForward)]
        c.skipBackwardCommand.preferredIntervals = [NSNumber(value: AppSettings.shared.skipBackward)]
        let track = AppSettings.shared.externalControls == .track
        c.skipForwardCommand.isEnabled = !track
        c.skipBackwardCommand.isEnabled = !track
        c.nextTrackCommand.isEnabled = track || !chapters.isEmpty
        c.previousTrackCommand.isEnabled = track || !chapters.isEmpty
    }
}
