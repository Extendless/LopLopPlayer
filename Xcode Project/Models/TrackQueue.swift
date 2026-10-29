struct TrackQueue {
    private(set) var tracks: [Track] = []
    mutating func append(_ items: [Track]) { tracks.append(contentsOf: items) }
    mutating func prepend(_ item: Track) { tracks.insert(item, at: 0) }
    mutating func dequeue() -> Track? { tracks.isEmpty ? nil : tracks.removeFirst() }
    mutating func reconcile(with library: [Track]) {
        var available: [String: Track] = [:]
        available.reserveCapacity(library.count)
        for track in library where available[track.id] == nil {
            available[track.id] = track
        }
        tracks = tracks.compactMap { available[$0.id] }
    }
}

enum PlaybackLimits {
    static func clampedVolume(_ value: Double) -> Double { min(1, max(0, value.isFinite ? value : 0)) }
    static func clampedTime(_ seconds: Double, duration: Double) -> Double { min(max(0, duration.isFinite ? duration : 0), max(0, seconds.isFinite ? seconds : 0)) }
}
