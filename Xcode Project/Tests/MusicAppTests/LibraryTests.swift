import XCTest
@testable import MusicApp

final class LibraryTests: XCTestCase {
    func testAlbumGroupingUsesArtistTitleAndYear() {
        let one = Track(id: "a", url: URL(fileURLWithPath: "/a"), title: "One", artist: "Artist", album: "Record", albumArtist: "Artist", trackNumber: 2, discNumber: nil, duration: 1, genre: nil, year: 2020, artwork: nil)
        let two = Track(id: "b", url: URL(fileURLWithPath: "/b"), title: "Two", artist: "Artist", album: "Record", albumArtist: "Artist", trackNumber: 1, discNumber: nil, duration: 1, genre: nil, year: 2020, artwork: nil)
        let albums = LibraryBuilder.albums(from: [one, two])
        XCTAssertEqual(albums.count, 1)
        XCTAssertEqual(albums[0].tracks.map(\.title), ["Two", "One"])
    }

    func testDifferentTrackReleaseYearsStayTogetherAndUseNewestYear() {
        let originalRelease = Track(id: "a", url: URL(fileURLWithPath: "/a"), title: "Track One", artist: "Artist", album: "Record", albumArtist: "Artist", trackNumber: 1, discNumber: nil, duration: 1, genre: nil, year: 2019, artwork: nil)
        let reissue = Track(id: "b", url: URL(fileURLWithPath: "/b"), title: "Track Two", artist: "Artist", album: "Record", albumArtist: "Artist", trackNumber: 2, discNumber: nil, duration: 1, genre: nil, year: 2024, artwork: nil)

        let albums = LibraryBuilder.albums(from: [originalRelease, reissue])

        XCTAssertEqual(albums.count, 1)
        XCTAssertEqual(albums[0].year, 2024)
        XCTAssertEqual(albums[0].tracks.count, 2)
    }

    func testGuestArtistCreditStaysWithLeadArtistAlbum() {
        let lead = Track(id: "a", url: URL(fileURLWithPath: "/a"), title: "Track One", artist: "Sungazer", album: "Perihelion", albumArtist: "Sungazer", trackNumber: 1, discNumber: nil, duration: 1, genre: nil, year: 2024, artwork: nil)
        let guest = Track(id: "b", url: URL(fileURLWithPath: "/b"), title: "Track Two", artist: "Sungazer & Plini", album: "Perihelion", albumArtist: "Sungazer & Plini", trackNumber: 2, discNumber: nil, duration: 1, genre: nil, year: 2024, artwork: nil)

        let albums = LibraryBuilder.albums(from: [lead, guest])

        XCTAssertEqual(albums.count, 1)
        XCTAssertEqual(albums[0].albumArtist, "Sungazer")
        XCTAssertEqual(albums[0].tracks.map(\.title), ["Track One", "Track Two"])
    }

    func testArtistGroupingProvidesAlbumsFallbackAndProfileImage() {
        let first = Track(id: "a", url: URL(fileURLWithPath: "/a"), title: "One", artist: "Beyoncé", album: "Renaissance", albumArtist: "Beyoncé", trackNumber: 1, discNumber: nil, duration: 1, genre: nil, year: 2022, artwork: nil)
        let second = Track(id: "b", url: URL(fileURLWithPath: "/b"), title: "Two", artist: "BEYONCÉ", album: "Lemonade", albumArtist: "BEYONCÉ", trackNumber: nil, discNumber: nil, duration: 1, genre: nil, year: 2016, artwork: nil)
        let fallback = Track(id: "c", url: URL(fileURLWithPath: "/c"), title: "Three", artist: "Solo", album: "Single", albumArtist: "", trackNumber: nil, discNumber: nil, duration: 1, genre: nil, year: nil, artwork: nil)
        let profile = Data([1, 2, 3])
        let artists = LibraryBuilder.artists(from: [first, second, fallback], profileImages: [LibraryBuilder.artistID(for: "Beyoncé"): profile])
        XCTAssertEqual(artists.count, 2)
        let beyonce = try! XCTUnwrap(artists.first { $0.name.localizedCaseInsensitiveContains("Beyoncé") })
        XCTAssertEqual(beyonce.albums.count, 2)
        XCTAssertEqual(beyonce.profileImage, profile)
        XCTAssertEqual(artists.first { $0.name == "Solo" }?.albums.count, 1)
    }

    func testStableIdentitySurvivesMetadataAndModificationChanges() {
        let url = URL(fileURLWithPath: "/music/track.flac")
        XCTAssertEqual(LibraryBuilder.stableID(url: url, fileSize: 10, modified: Date(timeIntervalSince1970: 1)), LibraryBuilder.stableID(url: url, fileSize: 99, modified: Date()))
    }

    func testSearchMatchesTrackAlbumAndArtistFields() {
        let track = Track(id: "a", url: URL(fileURLWithPath: "/a"), title: "Blue Train", artist: "John Coltrane", album: "Giant Steps", albumArtist: "John Coltrane", trackNumber: nil, discNumber: nil, duration: 1, genre: "Jazz", year: nil, artwork: nil)
        XCTAssertTrue(track.searchable.localizedCaseInsensitiveContains("giant steps"))
        XCTAssertTrue(track.searchable.localizedCaseInsensitiveContains("coltrane"))
        XCTAssertTrue(track.searchable.localizedCaseInsensitiveContains("jazz"))
    }

    func testQueueAppendAndReconciliation() {
        var queue = TrackQueue()
        let first = Track(id: "a", url: URL(fileURLWithPath: "/a"), title: "One", artist: "Artist", album: "Album", albumArtist: "Artist", trackNumber: nil, discNumber: nil, duration: 1, genre: nil, year: nil, artwork: nil)
        let second = Track(id: "b", url: URL(fileURLWithPath: "/b"), title: "Two", artist: "Artist", album: "Album", albumArtist: "Artist", trackNumber: nil, discNumber: nil, duration: 1, genre: nil, year: nil, artwork: nil)
        queue.append([first]); queue.append([second])
        XCTAssertEqual(queue.tracks.map(\.id), ["a", "b"])
        XCTAssertEqual(queue.dequeue()?.id, "a")
        queue.reconcile(with: [second])
        XCTAssertEqual(queue.tracks.map(\.id), ["b"])
    }

    func testPlaybackValuesClampToSupportedRange() {
        XCTAssertEqual(PlaybackLimits.clampedVolume(1.4), 1)
        XCTAssertEqual(PlaybackLimits.clampedVolume(-0.2), 0)
        XCTAssertEqual(PlaybackLimits.clampedTime(12, duration: 8), 8)
        XCTAssertEqual(PlaybackLimits.clampedTime(-2, duration: 8), 0)
    }

    @MainActor
    func testPlaybackVolumeCanBeUpdatedRepeatedly() {
        let playback = PlaybackController()
        playback.volume = 0.4
        XCTAssertEqual(playback.volume, 0.4, accuracy: 0.0001)
        playback.volume = 1.4
        XCTAssertEqual(playback.volume, 1)
        playback.volume = -0.2
        XCTAssertEqual(playback.volume, 0)
    }

    func testLRCLyricsParseTimestampsAndTrackActiveLine() {
        let lyrics = LyricsParser.timedLines(from: "[00:01.25]First line\n[00:03.500][00:04.00]Repeated line\n[ar:Artist]\nNo timestamp")
        XCTAssertEqual(lyrics.map(\.text), ["First line", "Repeated line", "Repeated line"])
        XCTAssertEqual(lyrics.map(\.time), [1.25, 3.5, 4.0])
        XCTAssertNil(LyricsParser.activeLine(in: lyrics, at: 0.5))
        XCTAssertEqual(LyricsParser.activeLine(in: lyrics, at: 3.75), 1)
        XCTAssertEqual(LyricsParser.activeLine(in: lyrics, at: 5), 2)
    }
}
