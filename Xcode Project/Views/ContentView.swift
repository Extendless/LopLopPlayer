import SwiftUI

struct ContentView: View {
    @Bindable var store: LibraryStore
    var discordPresence: DiscordPresenceService
    var lastFM: LastFMService
    @State private var showingSearch = false
    @State private var showingArtists = false
    @State private var backgroundTint = Color(white: 0.10)
    private func gridColumns(for width: CGFloat) -> [GridItem] {
        let count = min(5, max(2, Int((width + 20) / 130)))
        return Array(repeating: GridItem(.flexible(), spacing: 20), count: count)
    }

    var body: some View {
        ZStack {
        HSplitView {
            if let album = store.selectedAlbum {
                AlbumDetail(album: album, playback: store.playback) { store.selectedAlbum = nil }
                    .frame(minWidth: 320, idealWidth: 420, maxWidth: 620, maxHeight: .infinity)
                    .layoutPriority(1)
            }
        VStack(spacing: 0) {
            HStack {
                if store.selectedArtist != nil {
                    Button { store.closeArtist() } label: { Label("Artists", systemImage: "chevron.left") }.buttonStyle(.plain)
                    Text("/ \(store.selectedArtist?.name ?? "")").font(.title3).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Picker("Library view", selection: $showingArtists) {
                        Text("Albums").tag(false)
                        Text("Artists").tag(true)
                    }.pickerStyle(.segmented).frame(width: 190)
                }
                Spacer()
                if store.isScanning {
                    Group {
                        if store.scanProgress > 0 { ProgressView(value: store.scanProgress) }
                        else { ProgressView() }
                    }.frame(width: 110)
                }
                Text(store.scanStatus).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Button { Task { await store.rescan() } } label: { Image(systemName: "arrow.clockwise") }.help("Rescan library")
                Button { store.showPalette = true } label: { Label("Search", systemImage: "magnifyingglass") }.keyboardShortcut("p", modifiers: .command)
            }.padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 14)

            if let artist = store.selectedArtist {
                ArtistDetailPage(artist: artist, playback: store.playback, setProfileImage: { store.setArtistProfileImage($0, for: artist.id) }, openAlbum: { store.selectedAlbum = $0 })
            } else if store.tracks.isEmpty {
                EmptyLibraryView(store: store)
            } else if showingArtists {
                if store.artists.isEmpty {
                    ContentUnavailableView("No artists found", systemImage: "person.crop.circle", description: Text("Artists will appear here when your library has tracks."))
                } else {
                    GeometryReader { geometry in
                        ScrollView {
                            LazyVGrid(columns: gridColumns(for: geometry.size.width - 48), alignment: .leading, spacing: 24) {
                                ForEach(store.artists) { artist in
                                    ArtistTile(artist: artist).contentShape(Rectangle()).onTapGesture { store.openArtist(artist) }
                                        .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
                                        .accessibilityAction { store.openArtist(artist) }
                                }
                            }.padding(.horizontal, 24).padding(.vertical, 22)
                        }
                    }
                }
            } else if store.albums.isEmpty {
                ContentUnavailableView("No albums found", systemImage: "music.note.list", description: Text("Try another music folder or rescan."))
            } else {
                GeometryReader { geometry in
                    ScrollView {
                        LazyVGrid(columns: gridColumns(for: geometry.size.width - 48), alignment: .leading, spacing: 22) {
                            ForEach(store.albums) { album in
                                AlbumTile(album: album).contentShape(Rectangle()).onTapGesture { store.selectedAlbum = album }
                                    .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
                                    .accessibilityAction { store.selectedAlbum = album }
                                    .contextMenu {
                                        Button("Play Album") { if let first = album.tracks.first { store.playback.play(first); store.playback.add(Array(album.tracks.dropFirst())) } }
                                        Button("Add Album to Queue") { store.playback.add(album.tracks) }
                                    }
                            }
                        }.padding(.horizontal, 24).padding(.bottom, 24)
                    }
                }
            }
            NowPlayingBar(playback: store.playback)
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            NowPlayingSidebar(playback: store.playback)
        }
        if store.playback.showLyrics {
            LyricsView(playback: store.playback)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .zIndex(1)
                .transition(.opacity)
        }
        }
        .background {
            ZStack {
                backgroundTint
                LinearGradient(colors: [backgroundTint.opacity(0.62), Color(white: 0.055), Color(white: 0.035)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }.ignoresSafeArea()
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $store.showPalette) { CommandPalette(store: store).frame(width: 620, height: 470) }
        .task {
            store.monitorFolders()
            discordPresence.playbackChanged(track: store.playback.current, isPlaying: store.playback.isPlaying, progress: store.playback.progress)
            lastFM.playbackChanged(track: store.playback.current, isPlaying: store.playback.isPlaying, playedDuration: store.playback.playedDuration, generation: store.playback.playbackGeneration)
            if store.tracks.isEmpty { await store.rescan() }
        }
        .onChange(of: store.playback.current?.id) { _, _ in
            discordPresence.playbackChanged(track: store.playback.current, isPlaying: store.playback.isPlaying, progress: store.playback.progress)
            lastFM.playbackChanged(track: store.playback.current, isPlaying: store.playback.isPlaying, playedDuration: store.playback.playedDuration, generation: store.playback.playbackGeneration)
        }
        .onChange(of: store.playback.isPlaying) { _, _ in
            discordPresence.playbackChanged(track: store.playback.current, isPlaying: store.playback.isPlaying, progress: store.playback.progress)
            lastFM.playbackChanged(track: store.playback.current, isPlaying: store.playback.isPlaying, playedDuration: store.playback.playedDuration, generation: store.playback.playbackGeneration)
        }
        .onChange(of: store.playback.playbackGeneration) { _, _ in
            lastFM.playbackChanged(track: store.playback.current, isPlaying: store.playback.isPlaying, playedDuration: store.playback.playedDuration, generation: store.playback.playbackGeneration)
        }
        .onChange(of: store.playback.playedDuration) { _, _ in
            lastFM.playbackChanged(track: store.playback.current, isPlaying: store.playback.isPlaying, playedDuration: store.playback.playedDuration, generation: store.playback.playbackGeneration)
        }
        .task(id: store.playback.current?.id) {
            backgroundTint = ArtworkColorSampler.sample(
                from: store.playback.current?.artwork,
                brightness: 0.10...0.24,
                minimumSaturation: 0.40,
                fallback: Color(white: 0.10)
            )
        }
        .animation(.easeInOut(duration: 1.0), value: backgroundTint)
        .onChange(of: store.search) { _, value in showingSearch = !value.isEmpty }
    }
}

struct ArtistTile: View {
    let artist: Artist
    var body: some View {
        VStack(spacing: 10) {
            Group {
                if let data = artist.profileImage, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    ZStack { Color(white: 0.22); Image(systemName: "person.fill").font(.system(size: 42)).foregroundStyle(.white.opacity(0.48)) }
                }
            }.frame(maxWidth: .infinity).aspectRatio(1, contentMode: .fit).clipShape(Circle())
            Text(artist.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).frame(maxWidth: .infinity)
        }.accessibilityLabel("\(artist.name), artist")
    }
}

private struct EmptyLibraryView: View {
    var store: LibraryStore
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.house").font(.system(size: 42)).foregroundStyle(.secondary)
            Text(store.folders.roots.isEmpty ? "Your music belongs here" : "No playable tracks found").font(.title2)
            Text(store.folders.roots.isEmpty ? "Choose a folder containing your music. LopLop Player will scan it and remember access." : store.scanStatus).foregroundStyle(.secondary)
            Button("Choose Music Folder…") { store.chooseFolder() }.buttonStyle(.borderedProminent)
            if !store.folders.roots.isEmpty { Button("Rescan") { Task { await store.rescan() } } }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AlbumTile: View {
    let album: Album
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ArtworkView(data: album.artwork).aspectRatio(1, contentMode: .fill)
            LinearGradient(colors: [.clear, .black.opacity(0.86)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 3) {
                Text(album.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(album.albumArtist).font(.system(size: 11)).foregroundStyle(.white.opacity(0.82)).lineLimit(1)
            }.padding(10)
        }.aspectRatio(1, contentMode: .fit).clipped().accessibilityLabel("\(album.title), \(album.albumArtist), album")
    }
}

struct ArtworkView: View {
    let data: Data?
    var body: some View {
        Group {
            if let data, let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFill() }
            else { ZStack { Color(white: 0.22); Image(systemName: "music.note").font(.system(size: 38)).foregroundStyle(.white.opacity(0.35)) } }
        }.clipped()
    }
}
