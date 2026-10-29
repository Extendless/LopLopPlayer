import Foundation
import Observation
import ImageIO

@MainActor @Observable final class LibraryStore {
    let folders = FolderAccess()
    let playback = PlaybackController()
    var tracks: [Track] = []
    private(set) var libraryRevision = 0
    private(set) var albums: [Album] = []
    private(set) var artists: [Artist] = []
    private(set) var artistProfileImages: [String: Data] = UserDefaults.standard.dictionary(forKey: "artistProfileImages") as? [String: Data] ?? [:]
    var isScanning = false
    var scanStatus = "Choose a music folder to get started."
    var scanProgress = 0.0
    var selectedAlbum: Album?
    var selectedArtistID: String?
    var selectedArtist: Artist? { artists.first { $0.id == selectedArtistID } }
    var search = ""
    var showPalette = false
    private var monitor: FolderMonitor?
    private var debounce: Task<Void, Never>?

    init() { folders.restore() }
    func addFolder(_ url: URL) { do { try folders.add(url); monitorFolders(); Task { await rescan() } } catch { scanStatus = "Could not save folder permission: \(error.localizedDescription)" } }
    func chooseFolder() { if let url = FolderAccess.chooseFolder() { addFolder(url) } }
    func removeFolder(_ url: URL) { folders.remove(url); monitorFolders(); Task { await rescan() } }
    func rescan() async {
        guard !isScanning else {
            // File events can arrive in bursts while the walk is running. The
            // active scan already covers the library; don't queue another scan
            // that would retain a second full track array in memory.
            return
        }
        guard !folders.roots.isEmpty else {
            tracks = []; albums = []; artists = []; libraryRevision &+= 1; playback.reconcile(with: [])
            scanStatus = "No music folders yet. Add a folder in Settings."
            return
        }
        isScanning = true; scanProgress = 0; scanStatus = "Scanning music…"
        let result = await LibraryScanner.scan(folders.roots) { done, total in
            Task { @MainActor in
                if total > 0 {
                    self.scanProgress = Double(done) / Double(total)
                } else if done > 0 {
                    self.scanStatus = "Scanning music… \(done.formatted()) items checked"
                }
            }
        }
        scanStatus = "Organizing library…"
        let profileImages = artistProfileImages
        let index = await Task.detached(priority: .utility) {
            let tracks = result.tracks
            let albums = LibraryBuilder.albums(from: tracks)
            let artists = LibraryBuilder.artists(from: tracks, albums: albums, profileImages: profileImages)
            return (tracks, albums, artists)
        }.value
        tracks = index.0
        albums = index.1
        artists = index.2
        libraryRevision &+= 1
        playback.reconcile(with: index.0)
        scanStatus = "\(tracks.count) tracks · \(result.skipped) files skipped"
        isScanning = false
    }
    func monitorFolders() {
        monitor?.cancel()
        monitor = FolderMonitor(urls: folders.roots) { [weak self] in
            Task { @MainActor in
                self?.debounce?.cancel()
                self?.debounce = Task { try? await Task.sleep(for: .seconds(1.2)); guard !Task.isCancelled else { return }; await self?.rescan() }
            }
        }
    }
    var results: [Track] { search.isEmpty ? tracks : tracks.filter { $0.searchable.localizedCaseInsensitiveContains(search) } }
    func setArtistProfileImage(_ data: Data, for artistID: String) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 720] as CFDictionary),
              let destinationData = NSMutableData() as CFMutableData? else { return }
        guard let destination = CGImageDestinationCreateWithData(destinationData, "public.jpeg" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return }
        artistProfileImages[artistID] = destinationData as Data
        UserDefaults.standard.set(artistProfileImages, forKey: "artistProfileImages")
        artists = artists.map { artist in
            guard artist.id == artistID else { return artist }
            return Artist(id: artist.id, name: artist.name, albums: artist.albums, profileImage: destinationData as Data)
        }
    }

    func openArtist(_ artist: Artist) { selectedArtistID = artist.id }
    func closeArtist() { selectedArtistID = nil }
    func playSearchFirst() { if let track = results.first { playback.play(track) } }
}
