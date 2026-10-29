import Foundation
import AVFoundation
import SQLite3
import ImageIO

struct ScanResult: Sendable { var tracks: [Track]; var skipped: Int }

private struct PendingMetadata: Sendable {
    var offset: Int
    var url: URL
    var size: Int64
    var modified: Date
}

private final class AudioFileDiscovery {
    private let roots: [URL]
    private var rootIndex = 0
    private var enumerator: FileManager.DirectoryEnumerator?
    private let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isReadableKey]
    private(set) var visitedCount = 0
    private(set) var isFinished = false

    init(roots: [URL]) { self.roots = roots }

    func nextBatch(limit: Int, maximumEntries: Int = 512) -> [URL] {
        var batch: [URL] = []
        batch.reserveCapacity(limit)
        var visitedThisBatch = 0
        while batch.count < limit && visitedThisBatch < maximumEntries {
            if let entry = enumerator?.nextObject() {
                visitedCount += 1
                visitedThisBatch += 1
                if let url = entry as? URL, LibraryScanner.extensions.contains(url.pathExtension.lowercased()) {
                    batch.append(url)
                }
                continue
            }
            enumerator = nil
            guard rootIndex < roots.count else { isFinished = true; break }
            let root = roots[rootIndex]
            rootIndex += 1
            enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        }
        return batch
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func compactArtwork(_ data: Data) -> Data? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 384
          ] as CFDictionary),
          let output = NSMutableData() as CFMutableData?,
          let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return output as Data
}

private final class TrackMetadataCache {
    private var database: OpaquePointer?
    private var lookup: OpaquePointer?
    private var upsert: OpaquePointer?
    private var previousDatabase: OpaquePointer?
    private var previousLookup: OpaquePointer?
    private let encoder = PropertyListEncoder()
    private let decoder = PropertyListDecoder()

    init?() {
        encoder.outputFormat = .binary
        guard let url = Self.url() else { return nil }
        do { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        catch { return nil }
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else { return nil }
        sqlite3_busy_timeout(database, 1500)
        guard sqlite3_exec(database, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; CREATE TABLE IF NOT EXISTS track_cache (path TEXT PRIMARY KEY NOT NULL, file_size INTEGER NOT NULL, modification_time REAL NOT NULL, track BLOB NOT NULL);", nil, nil, nil) == SQLITE_OK,
              sqlite3_prepare_v2(database, "SELECT track FROM track_cache WHERE path = ?1 AND file_size = ?2 AND modification_time = ?3", -1, &lookup, nil) == SQLITE_OK,
              sqlite3_prepare_v2(database, "INSERT INTO track_cache(path, file_size, modification_time, track) VALUES(?1, ?2, ?3, ?4) ON CONFLICT(path) DO UPDATE SET file_size = excluded.file_size, modification_time = excluded.modification_time, track = excluded.track", -1, &upsert, nil) == SQLITE_OK else {
            return nil
        }
        if let previousURL = Self.previousCacheURL(),
           sqlite3_open_v2(previousURL.path, &previousDatabase, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
           let previousDatabase {
            _ = sqlite3_prepare_v2(previousDatabase, "SELECT track FROM track_cache WHERE path = ?1 AND file_size = ?2 AND modification_time = ?3", -1, &previousLookup, nil)
        }
        _ = sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil)
    }

    deinit {
        _ = sqlite3_exec(database, "COMMIT", nil, nil, nil)
        if let lookup { sqlite3_finalize(lookup) }
        if let upsert { sqlite3_finalize(upsert) }
        if let database { sqlite3_close(database) }
        if let previousLookup { sqlite3_finalize(previousLookup) }
        if let previousDatabase { sqlite3_close(previousDatabase) }
    }

    func track(path: String, size: Int64, modified: Date) -> Track? {
        if var track = cachedTrack(using: lookup, path: path, size: size, modified: modified) {
            // Lyrics are loaded only for the active track, not retained for the
            // entire library during startup.
            track.lyrics = nil
            track.timedLyrics = []
            return track
        }
        guard var track = cachedTrack(using: previousLookup, path: path, size: size, modified: modified) else { return nil }
        if let artwork = track.artwork { track.artwork = compactArtwork(artwork) }
        track.lyrics = nil
        track.timedLyrics = []
        store(track, path: path, size: size, modified: modified)
        return track
    }

    func store(_ track: Track, path: String, size: Int64, modified: Date) {
        guard let upsert, let data = try? encoder.encode(track) else { return }
        sqlite3_reset(upsert); sqlite3_clear_bindings(upsert)
        let result = data.withUnsafeBytes { bytes in
            guard bind(path, to: upsert, at: 1),
                  sqlite3_bind_int64(upsert, 2, size) == SQLITE_OK,
                  sqlite3_bind_double(upsert, 3, modified.timeIntervalSince1970) == SQLITE_OK else { return SQLITE_ERROR }
            return sqlite3_bind_blob(upsert, 4, bytes.baseAddress, Int32(data.count), sqliteTransient)
        }
        if result == SQLITE_OK { _ = sqlite3_step(upsert) }
    }

    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) -> Bool {
        value.withCString { sqlite3_bind_text(statement, index, $0, -1, sqliteTransient) == SQLITE_OK }
    }

    private func cachedTrack(using statement: OpaquePointer?, path: String, size: Int64, modified: Date) -> Track? {
        guard let statement else { return nil }
        sqlite3_reset(statement); sqlite3_clear_bindings(statement)
        guard bind(path, to: statement, at: 1),
              sqlite3_bind_int64(statement, 2, size) == SQLITE_OK,
              sqlite3_bind_double(statement, 3, modified.timeIntervalSince1970) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_blob(statement, 0) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, 0))
        guard count > 0 else { return nil }
        return try? decoder.decode(Track.self, from: Data(bytes: bytes, count: count))
    }

    private static func url() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "MusicApp", isDirectory: true)
            // v2 stores reduced artwork. Don't migrate the old JSON cache: it can
            // contain gigabytes of duplicated full-resolution album art.
            .appendingPathComponent("library-cache-v2.sqlite3")
    }

    private static func previousCacheURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "MusicApp", isDirectory: true)
            .appendingPathComponent("library-cache.sqlite3")
    }
}

enum LibraryScanner {
    static let extensions: Set<String> = ["mp3", "m4a", "m4b", "aac", "wav", "aiff", "aif", "caf", "alac", "flac"]

    static func scan(_ roots: [URL], progress: @escaping @Sendable (Int, Int) -> Void) async -> ScanResult {
        await Task.detached(priority: .utility) {
            let cache = TrackMetadataCache()
            var tracks: [Track] = []
            var skipped = 0
            var seenPaths: Set<String> = []
            var albumsWithArtwork: Set<String> = []
            // Stream discovered paths and process small batches. Keeping every
            // URL from a large library in memory delayed progress and inflated
            // peak memory before metadata scanning even began.
            let batchSize = 2
            var scanned = 0

            func processBatch(_ batch: [URL]) async {
                var batchTracks = Array<Track?>(repeating: nil, count: batch.count)
                var pending: [PendingMetadata] = []
                pending.reserveCapacity(batch.count)

                for (offset, url) in batch.enumerated() {
                    do {
                        let path = url.standardizedFileURL.path
                        guard seenPaths.insert(path).inserted else { continue }
                        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                        let size = Int64(values.fileSize ?? -1)
                        let modified = values.contentModificationDate ?? .distantPast
                        if let cached = cache?.track(path: path, size: size, modified: modified) {
                            batchTracks[offset] = cached
                        } else {
                            pending.append(PendingMetadata(offset: offset, url: url, size: size, modified: modified))
                        }
                    } catch {
                        skipped += 1
                    }
                }

                let pendingByOffset = Dictionary(uniqueKeysWithValues: pending.map { ($0.offset, $0) })
                let loaded = await withTaskGroup(of: (Int, Track?).self, returning: [(Int, Track?)].self) { group in
                    for item in pending {
                        group.addTask {
                            do {
                                return (item.offset, try await metadata(for: item.url, fileSize: item.size, modified: item.modified))
                            } catch {
                                return (item.offset, nil)
                            }
                        }
                    }
                    var results: [(Int, Track?)] = []
                    results.reserveCapacity(pending.count)
                    for await result in group { results.append(result) }
                    return results
                }

                for (offset, track) in loaded {
                    guard let track else { skipped += 1; continue }
                    guard let item = pendingByOffset[offset] else { skipped += 1; continue }
                    cache?.store(track, path: item.url.standardizedFileURL.path, size: item.size, modified: item.modified)
                    batchTracks[offset] = track
                }
                for offset in batchTracks.indices {
                    guard var track = batchTracks[offset], track.artwork != nil else { continue }
                    let albumKey = LibraryBuilder.albumArtworkKey(for: track)
                    if albumsWithArtwork.insert(albumKey).inserted { continue }
                    track.artwork = nil
                    batchTracks[offset] = track
                }
                tracks.append(contentsOf: batchTracks.compactMap { $0 })
            }

            let discovery = AudioFileDiscovery(roots: roots)
            var lastReportedEntries = 0
            var lastReportedTracks = 0
            while !Task.isCancelled && !discovery.isFinished {
                let batch = discovery.nextBatch(limit: batchSize)
                if !batch.isEmpty {
                    await processBatch(batch)
                    scanned += batch.count
                }
                let entriesAdvanced = discovery.visitedCount - lastReportedEntries >= 8_192
                let tracksAdvanced = scanned - lastReportedTracks >= 64
                if entriesAdvanced || tracksAdvanced || discovery.isFinished {
                    progress(discovery.visitedCount, 0) // total is unknown while streaming
                    lastReportedEntries = discovery.visitedCount
                    lastReportedTracks = scanned
                }
            }
            progress(scanned, scanned)
            return ScanResult(tracks: tracks, skipped: skipped)
        }.value
    }

    static func playbackMetadata(for url: URL) async -> (plain: String?, timed: [TimedLyric], artwork: Data?) {
        let asset = AVURLAsset(url: url)
        guard let metadata = try? await asset.load(.metadata) else { return (nil, [], nil) }
        var plain = try? await asset.load(.lyrics)
        if plain == nil, let item = metadata.first(where: { $0.identifier == .id3MetadataUnsynchronizedLyric }) {
            plain = try? await item.load(.stringValue)
        }
        var timed: [TimedLyric] = []
        for item in metadata where item.identifier == .id3MetadataSynchronizedLyric {
            guard let text = try? await item.load(.stringValue),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let timestamp = CMTimeGetSeconds(item.time)
            if timestamp.isFinite, timestamp >= 0 { timed.append(TimedLyric(time: timestamp, text: text)) }
        }
        let artwork: Data?
        if let artworkItem = metadata.first(where: { $0.commonKey == .commonKeyArtwork }),
           let original = try? await artworkItem.load(.dataValue) {
            artwork = compactArtwork(original)
        } else {
            artwork = nil
        }
        if timed.isEmpty, let plain { timed = LyricsParser.timedLines(from: plain) }
        timed.sort { $0.time < $1.time }
        return (plain, timed, artwork)
    }

    private static func metadata(for url: URL, fileSize: Int64, modified: Date) async throws -> Track {
        let asset = AVURLAsset(url: url)
        let metadata = try await asset.load(.metadata)
        let title = await string(.commonKeyTitle, in: metadata) ?? url.deletingPathExtension().lastPathComponent
        let artist = await string(.commonKeyArtist, in: metadata) ?? "Unknown Artist"
        let album = await string(.commonKeyAlbumName, in: metadata) ?? url.deletingLastPathComponent().lastPathComponent
        let albumArtistItem = metadata.first(where: { $0.identifier == .iTunesMetadataAlbumArtist })
        let albumArtist = (try? await albumArtistItem?.load(.stringValue)) ?? artist
        let itunesTrackNumber = await integer(identifier: .iTunesMetadataTrackNumber, in: metadata)
        let trackNumber: Int?
        if let itunesTrackNumber { trackNumber = itunesTrackNumber }
        else { trackNumber = await integer(identifier: .id3MetadataTrackNumber, in: metadata) }
        let discNumber = await integer(identifier: .iTunesMetadataDiscNumber, in: metadata)
        let genre = await string(identifier: .iTunesMetadataUserGenre, in: metadata)
        let iTunesReleaseDate = await string(identifier: .iTunesMetadataReleaseDate, in: metadata)
        let releaseDate: String?
        if let iTunesReleaseDate { releaseDate = iTunesReleaseDate }
        else { releaseDate = await string(identifier: .id3MetadataYear, in: metadata) }
        let year = releaseDate.flatMap { Int(String($0.prefix(4))) }
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        let artworkItem = metadata.first(where: { $0.commonKey == .commonKeyArtwork })
        let artwork: Data?
        if let artworkItem, let original = try? await artworkItem.load(.dataValue) {
            artwork = compactArtwork(original)
        } else { artwork = nil }
        let id = LibraryBuilder.stableID(url: url, fileSize: fileSize, modified: modified)
        return Track(id: id, url: url, title: title, artist: artist, album: album, albumArtist: albumArtist, trackNumber: trackNumber, discNumber: discNumber, duration: duration.isFinite ? duration : 0, genre: genre, year: year, artwork: artwork)
    }

    private static func string(_ key: AVMetadataKey, in metadata: [AVMetadataItem]) async -> String? {
        guard let item = metadata.first(where: { $0.commonKey == key }) else { return nil }
        return try? await item.load(.stringValue)
    }
    private static func string(identifier: AVMetadataIdentifier, in metadata: [AVMetadataItem]) async -> String? {
        guard let item = metadata.first(where: { $0.identifier == identifier }) else { return nil }
        return try? await item.load(.stringValue)
    }
    private static func integer(identifier: AVMetadataIdentifier, in metadata: [AVMetadataItem]) async -> Int? {
        guard let item = metadata.first(where: { $0.identifier == identifier }) else { return nil }
        if let value = try? await item.load(.numberValue) { return value.intValue }
        if let text = try? await item.load(.stringValue) { return Int(text.split(separator: "/").first ?? "") }
        return nil
    }

}
