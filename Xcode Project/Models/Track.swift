import Foundation

struct Track: Identifiable, Hashable, Codable, Sendable {
    private static let filenamePositionPatterns: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"^(?:cd|disc)[\s._-]*(\d+)[\s._-]+(?:track[\s._-]*)?(\d+)\b"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"^(\d{1,2})[-._](\d{1,3})(?:[-._\s]|$)"#, options: [.caseInsensitive]),
        try! NSRegularExpression(pattern: #"^(?:track[\s._-]*)?(\d{1,3})(?=$|[\s._-])"#, options: [.caseInsensitive])
    ]

    var id: String
    var url: URL
    var title: String
    var artist: String
    var album: String
    var albumArtist: String
    var trackNumber: Int?
    var discNumber: Int?
    var duration: Double
    var genre: String?
    var year: Int?
    var artwork: Data?
    var lyrics: String? = nil
    var timedLyrics: [TimedLyric] = []

    var identity: String { id }
    var filenameTrackPosition: (disc: Int?, track: Int?) {
        let stem = url.deletingPathExtension().lastPathComponent
        if let match = Self.firstMatch(Self.filenamePositionPatterns[0], in: stem),
           let disc = Int(match[0]), let track = Int(match[1]) {
            return (disc, track)
        }
        if let match = Self.firstMatch(Self.filenamePositionPatterns[1], in: stem),
           let disc = Int(match[0]), let track = Int(match[1]) {
            return (disc, track)
        }
        if let match = Self.firstMatch(Self.filenamePositionPatterns[2], in: stem),
           let track = Int(match[0]) {
            return (nil, track)
        }
        return (nil, nil)
    }

    private static func firstMatch(_ expression: NSRegularExpression, in string: String) -> [String]? {
        guard let match = expression.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: string) else { return nil }
            return String(string[range])
        }
    }
    var searchable: String { "\(title) \(artist) \(album) \(albumArtist) \(genre ?? "")".lowercased() }
}

struct TimedLyric: Hashable, Codable, Sendable {
    var time: Double
    var text: String
}

struct Album: Identifiable, Hashable, Sendable {
    var id: String { "\(albumArtist.lowercased())|\(title.lowercased())|\(year ?? 0)" }
    var title: String
    var albumArtist: String
    var year: Int?
    var tracks: [Track]
    var artwork: Data? { tracks.first(where: { $0.artwork != nil })?.artwork }
    var searchable: String { "\(title) \(albumArtist)".lowercased() }
}

struct Artist: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var albums: [Album]
    var profileImage: Data?
    var searchable: String { name.lowercased() }
}

enum LibraryBuilder {
    static func stableID(url: URL, fileSize: Int64, modified: Date?) -> String {
        // URL path is the stable anchor; metadata and mtime changes do not lose favorites.
        url.standardizedFileURL.path
    }

    static func albums(from tracks: [Track]) -> [Album] {
        var grouped: [String: [Int]] = [:]
        grouped.reserveCapacity(tracks.count / 8)
        for (index, track) in tracks.enumerated() {
            let key = albumArtworkKey(for: track)
            grouped[key, default: []].append(index)
        }
        return grouped.values.map { itemIndices in
            let positionedItems = itemIndices.map { index in
                (index, tracks[index].filenameTrackPosition, tracks[index].title.lowercased())
            }
            let sorted = positionedItems.sorted { left, right in
                let leftTrackInfo = tracks[left.0]
                let rightTrackInfo = tracks[right.0]
                let leftDisc = leftTrackInfo.discNumber ?? left.1.disc ?? 0
                let rightDisc = rightTrackInfo.discNumber ?? right.1.disc ?? 0
                if leftDisc != rightDisc { return leftDisc < rightDisc }
                let leftNumber = left.1.track ?? leftTrackInfo.trackNumber ?? Int.max
                let rightNumber = right.1.track ?? rightTrackInfo.trackNumber ?? Int.max
                if leftNumber != rightNumber { return leftNumber < rightNumber }
                return left.2 < right.2
            }
            let sortedIndices = sorted.map(\.0)
            let first = tracks[sortedIndices[0]]
            let displayArtist = sortedIndices
                .map { index in
                    let track = tracks[index]
                    return primaryAlbumArtist(track.albumArtist.isEmpty ? track.artist : track.albumArtist)
                }
                .first(where: { !$0.isEmpty }) ?? "Unknown Artist"
            let sortedTracks = sortedIndices.map { tracks[$0] }
            let year = itemIndices.compactMap { tracks[$0].year }.max()
            return Album(title: first.album, albumArtist: displayArtist, year: year, tracks: sortedTracks)
        }.sorted { $0.title.lowercased() < $1.title.lowercased() }
    }

    /// Collaboration credits such as “Sungazer & Plini” identify the lead album artist
    /// as Sungazer, keeping guest-featured tracks with the rest of the album.
    private static func primaryAlbumArtist(_ credit: String) -> String {
        let trimmed = credit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Unknown Artist" }
        let separators = [" & ", " feat. ", " feat ", " ft. ", " ft ", " featuring "]
        let lower = trimmed.lowercased()
        let boundary = separators
            .compactMap { lower.range(of: $0)?.lowerBound }
            .min()
        let primary = boundary.map { String(trimmed[..<$0]) } ?? trimmed
        return primary.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func albumArtworkKey(for track: Track) -> String {
        let artist = primaryAlbumArtist(track.albumArtist.isEmpty ? track.artist : track.albumArtist)
        return "\(artist.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased())|\(track.album.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    static func artists(from tracks: [Track], albums suppliedAlbums: [Album]? = nil, profileImages: [String: Data] = [:]) -> [Artist] {
        let albums = suppliedAlbums ?? albums(from: tracks)
        let grouped = Dictionary(grouping: albums) { artistID(for: $0.albumArtist) }
        return grouped.map { id, artistAlbums in
            let name = artistAlbums.first?.albumArtist ?? "Unknown Artist"
            return Artist(
                id: id,
                name: name,
                albums: artistAlbums.sorted { $0.title.lowercased() < $1.title.lowercased() },
                profileImage: profileImages[id]
            )
        }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    static func artistID(for name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
    }
}
