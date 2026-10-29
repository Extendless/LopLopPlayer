import SwiftUI

private struct PaletteSearchEntry<Value: Sendable>: Sendable {
    let searchText: String
    let value: Value
}

private struct PaletteSearchMatches: Sendable {
    var artists: [Artist] = []
    var albums: [Album] = []
    var tracks: [Track] = []
}

private struct PaletteSearchIndex: Sendable {
    let artists: [PaletteSearchEntry<Artist>]
    let albums: [PaletteSearchEntry<Album>]
    let tracks: [PaletteSearchEntry<Track>]

    init(tracks: [Track], albums: [Album], artists: [Artist]) {
        self.artists = artists.map { PaletteSearchEntry(searchText: $0.searchable, value: $0) }
        self.albums = albums.map { PaletteSearchEntry(searchText: $0.searchable, value: $0) }
        self.tracks = tracks.map { PaletteSearchEntry(searchText: $0.searchable, value: $0) }
    }

    func search(_ query: String) -> PaletteSearchMatches {
        guard !query.isEmpty else { return PaletteSearchMatches() }
        return PaletteSearchMatches(
            artists: Array(artists.lazy.filter { $0.searchText.localizedCaseInsensitiveContains(query) }.prefix(20).map(\.value)),
            albums: Array(albums.lazy.filter { $0.searchText.localizedCaseInsensitiveContains(query) }.prefix(20).map(\.value)),
            tracks: Array(tracks.lazy.filter { $0.searchText.localizedCaseInsensitiveContains(query) }.prefix(40).map(\.value))
        )
    }
}

struct CommandPalette: View {
    @Bindable var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var command = ""
    @State private var selectedIndex = 0
    @State private var searchIndex = PaletteSearchIndex(tracks: [], albums: [], artists: [])
    @State private var matches = PaletteSearchMatches()

    private var commands: [PaletteCommand] {
        PaletteCommand.allCases.filter { item in
            item.isAvailable(in: store) && (command.isEmpty || item.searchText.localizedCaseInsensitiveContains(command))
        }
    }
    private var artists: [Artist] { matches.artists }
    private var albums: [Album] { matches.albums }
    private var tracks: [Track] { matches.tracks }
    private var itemCount: Int { commands.count + matches.artists.count + matches.albums.count + matches.tracks.count }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search tracks, albums, artists, or commands", text: $command)
                    .textFieldStyle(.plain).focused($focused).onSubmit(activateSelected)
                    .onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }
                    .onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
            }.padding(16)
            Divider()

            ScrollViewReader { proxy in
                List {
                    if !commands.isEmpty {
                        Section("Actions") {
                            ForEach(Array(commands.enumerated()), id: \.element) { offset, item in
                                row(at: offset, action: { perform(item) }) {
                                    HStack { Image(systemName: item.symbol).frame(width: 20); Text(item.title(in: store)); Spacer(); Text(item.shortcut).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                    if !artists.isEmpty {
                        Section("Artists") {
                            ForEach(Array(artists.enumerated()), id: \.element.id) { offset, artist in
                                let index = commands.count + offset
                                row(at: index, action: { store.openArtist(artist); dismiss() }) {
                                    HStack(spacing: 10) {
                                        Group {
                                            if let data = artist.profileImage, let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFill() }
                                            else { ZStack { Color(white: 0.22); Image(systemName: "person.fill").foregroundStyle(.white.opacity(0.5)) } }
                                        }.frame(width: 38, height: 38).clipShape(Circle())
                                        VStack(alignment: .leading) { Text(artist.name); Text("\(artist.albums.count) \(artist.albums.count == 1 ? "album" : "albums")").font(.caption).foregroundStyle(.secondary) }
                                        Spacer(); Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    if !albums.isEmpty {
                        Section("Albums") {
                            ForEach(Array(albums.enumerated()), id: \.element.id) { offset, album in
                                let index = commands.count + artists.count + offset
                                row(at: index, action: { store.selectedAlbum = album; dismiss() }) {
                                    HStack(spacing: 10) { ArtworkView(data: album.artwork).frame(width: 38, height: 38); VStack(alignment: .leading) { Text(album.title); Text(album.albumArtist).font(.caption).foregroundStyle(.secondary) }; Spacer() }
                                }
                            }
                        }
                    }
                    if !tracks.isEmpty {
                        Section("Tracks") {
                            ForEach(Array(tracks.enumerated()), id: \.element.id) { offset, track in
                                let index = commands.count + artists.count + albums.count + offset
                                row(at: index, action: { store.playback.play(track); dismiss() }) {
                                    HStack { ArtworkView(data: track.artwork).frame(width: 34, height: 34); VStack(alignment: .leading) { Text(track.title); Text("\(track.artist) · \(track.album)").font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "play.fill").foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .onChange(of: selectedIndex) { _, index in
                    withAnimation(.easeInOut(duration: 0.16)) { proxy.scrollTo(index, anchor: .center) }
                }
                .onChange(of: command) { _, _ in selectedIndex = 0 }
                .onChange(of: itemCount) { _, count in selectedIndex = min(selectedIndex, max(0, count - 1)) }
            }

            HStack { Text("↑ ↓ Navigate"); Spacer(); Text("↵ Open or run · Esc Close") }.font(.caption).foregroundStyle(.secondary).padding(10)
        }
        .onAppear { focused = true }
        .task(id: store.libraryRevision) {
            let sourceTracks = store.tracks
            let sourceAlbums = store.albums
            let sourceArtists = store.artists
            let index = await Task.detached(priority: .utility) {
                PaletteSearchIndex(tracks: sourceTracks, albums: sourceAlbums, artists: sourceArtists)
            }.value
            guard !Task.isCancelled else { return }
            searchIndex = index
            await updateMatches(for: command)
        }
        .task(id: command) {
            let query = command
            try? await Task.sleep(for: .milliseconds(70))
            guard !Task.isCancelled else { return }
            await updateMatches(for: query)
        }
    }

    private func row<Label: View>(at index: Int, action: @escaping () -> Void, @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            label().padding(.horizontal, 8).padding(.vertical, 5)
                .background(index == selectedIndex ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).id(index).accessibilityValue(index == selectedIndex ? "Selected" : "")
    }

    private func moveSelection(by amount: Int) {
        guard itemCount > 0 else { return }
        selectedIndex = (selectedIndex + amount + itemCount) % itemCount
    }

    private func activateSelected() {
        guard itemCount > 0 else { return }
        if selectedIndex < commands.count { perform(commands[selectedIndex]); return }
        var index = selectedIndex - commands.count
        if index < artists.count { store.openArtist(artists[index]); dismiss(); return }
        index -= artists.count
        if index < albums.count { store.selectedAlbum = albums[index]; dismiss(); return }
        index -= albums.count
        if tracks.indices.contains(index) { store.playback.play(tracks[index]); dismiss() }
    }

    @MainActor
    private func updateMatches(for query: String) async {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { matches = PaletteSearchMatches(); return }
        let index = searchIndex
        let result = await Task.detached(priority: .userInitiated) {
            index.search(normalized)
        }.value
        guard command.trimmingCharacters(in: .whitespacesAndNewlines) == normalized else { return }
        matches = result
    }

    private func perform(_ item: PaletteCommand) {
        switch item {
        case .playPause: store.playback.toggle()
        case .skipForward, .nextTrack: store.playback.next()
        case .skipBackward, .previousTrack: store.playback.previous()
        case .favorite: store.playback.toggleFavorite()
        case .addAlbumQueue: if let album = store.selectedAlbum { store.playback.add(album.tracks) }
        case .showLyrics:
            dismiss()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                store.playback.showLyrics = true
            }
            return
        }
        dismiss()
    }
}

@MainActor private enum PaletteCommand: String, CaseIterable, Hashable {
    case playPause, skipForward, skipBackward, nextTrack, previousTrack, favorite, addAlbumQueue, showLyrics

    var searchText: String {
        switch self {
        case .playPause: "play pause"
        case .skipForward: "skip forward"
        case .skipBackward: "skip backward"
        case .nextTrack: "next track"
        case .previousTrack: "previous track"
        case .favorite: "favorite"
        case .addAlbumQueue: "add album queue"
        case .showLyrics: "show lyrics"
        }
    }

    var shortcut: String {
        switch self {
        case .playPause: "Space"
        case .skipForward: "→"
        case .skipBackward: "←"
        case .nextTrack: "⇧→"
        case .previousTrack: "⇧←"
        case .favorite, .addAlbumQueue, .showLyrics: ""
        }
    }

    var symbol: String {
        switch self {
        case .playPause: "play.fill"
        case .skipForward: "forward.fill"
        case .skipBackward: "backward.fill"
        case .nextTrack: "forward.end.fill"
        case .previousTrack: "backward.end.fill"
        case .favorite: "heart"
        case .addAlbumQueue: "text.badge.plus"
        case .showLyrics: "quote.bubble"
        }
    }

    func isAvailable(in store: LibraryStore) -> Bool {
        switch self {
        case .addAlbumQueue: store.selectedAlbum != nil
        case .showLyrics: store.playback.current != nil
        default: true
        }
    }

    func title(in store: LibraryStore) -> String {
        switch self {
        case .playPause: "Play / Pause"
        case .skipForward: "Skip Forward"
        case .skipBackward: "Skip Backward"
        case .nextTrack: "Next Track"
        case .previousTrack: "Previous Track"
        case .favorite: store.playback.isFavorite ? "Unfavorite Current Track" : "Favorite Current Track"
        case .addAlbumQueue: "Add Viewed Album to Queue"
        case .showLyrics: "Show Lyrics"
        }
    }
}
