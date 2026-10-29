import AVFoundation
import Foundation
import Observation

@MainActor @Observable final class PlaybackController {
    private var pending = TrackQueue()
    private var history: [Track] = []
    var queue: [Track] { pending.tracks }
    var current: Track?
    var isPlaying = false
    var progress: Double = 0
    private(set) var playedDuration: Double = 0
    private(set) var playbackGeneration = 0
    var showLyrics = false
    private var storedVolume = 0.75
    var volume: Double {
        get { storedVolume }
        set {
            let clamped = PlaybackLimits.clampedVolume(newValue)
            storedVolume = clamped
            player.volume = Float(clamped)
        }
    }
    var error: String?
    private let player = AVPlayer()
    private var observer: Any?
    private var previousObservedTime: Double?
    private var completionObserver: NSObjectProtocol?
    private var lyricsTask: Task<Void, Never>?
    private var favorites = Set(UserDefaults.standard.stringArray(forKey: "favoriteTrackIDs") ?? [])
    var isFavorite: Bool { current.map { favorites.contains($0.id) } ?? false }

    init() {
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                let currentTime = CMTimeGetSeconds(time)
                if let previous = self.previousObservedTime {
                    let delta = currentTime - previous
                    if self.isPlaying, delta > 0, delta <= 2 { self.playedDuration += delta }
                }
                self.previousObservedTime = currentTime.isFinite ? currentTime : nil
                self.progress = currentTime
            }
        }
        completionObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor in
                guard let self, notification.object as? AVPlayerItem === self.player.currentItem else { return }
                self.next()
            }
        }
    }
    var duration: Double { current?.duration ?? 0 }
    func play(_ track: Track) {
        if let current, current.id != track.id { history.append(current) }
        start(track)
    }
    private func start(_ track: Track) {
        lyricsTask?.cancel()
        current = track
        progress = 0
        playedDuration = 0
        previousObservedTime = 0
        playbackGeneration &+= 1
        error = nil
        player.replaceCurrentItem(with: AVPlayerItem(url: track.url))
        player.play()
        isPlaying = true
        let trackID = track.id
        lyricsTask = Task { [weak self] in
            let loaded = await LibraryScanner.playbackMetadata(for: track.url)
            guard !Task.isCancelled, let self, self.current?.id == trackID, var updated = self.current else { return }
            updated.lyrics = loaded.plain
            updated.timedLyrics = loaded.timed
            if updated.artwork == nil { updated.artwork = loaded.artwork }
            self.current = updated
        }
    }
    func toggle() { guard current != nil else { if !pending.tracks.isEmpty { next() }; return }; if isPlaying { player.pause() } else { if duration > 0 && progress >= duration { seek(0) }; player.play() }; isPlaying.toggle() }
    func add(_ tracks: [Track]) { pending.append(tracks) }
    func reconcile(with tracks: [Track]) {
        let available = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        pending.reconcile(with: tracks)
        if let current, let replacement = available[current.id] { self.current = replacement }
        else if current != nil {
            player.pause(); player.replaceCurrentItem(with: nil); current = nil; isPlaying = false; progress = 0; playedDuration = 0; previousObservedTime = nil
        }
    }
    func next() {
        guard let track = pending.dequeue() else { isPlaying = false; return }
        guard FileManager.default.isReadableFile(atPath: track.url.path) else { error = "\(track.title) is unavailable. Skipping it."; next(); return }
        if let current, current.id != track.id { history.append(current) }
        start(track)
    }
    func previous() {
        guard progress <= 3, let previous = history.popLast() else { seek(0); return }
        if let current { pending.prepend(current) }
        start(previous)
    }
    func seek(_ seconds: Double) { player.seek(to: CMTime(seconds: PlaybackLimits.clampedTime(seconds, duration: duration), preferredTimescale: 600)) }
    func skip(_ seconds: Double) { seek(min(duration, max(0, progress + seconds))) }
    func toggleFavorite() { guard let current else { return }; if !favorites.insert(current.id).inserted { favorites.remove(current.id) }; UserDefaults.standard.set(Array(favorites), forKey: "favoriteTrackIDs") }
}
