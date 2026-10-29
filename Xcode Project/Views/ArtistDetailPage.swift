import SwiftUI
import UniformTypeIdentifiers

struct ArtistDetailPage: View {
    let artist: Artist
    @Bindable var playback: PlaybackController
    let setProfileImage: (Data) -> Void
    let openAlbum: (Album) -> Void
    @State private var choosingImage = false
    @State private var imageError: String?

    private func columns(_ width: CGFloat) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 20), count: min(5, max(2, Int((width + 20) / 130))))
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 22) {
                        ZStack(alignment: .bottomTrailing) {
                            artistImage.frame(width: 148, height: 148).clipShape(Circle())
                            Button { choosingImage = true } label: { Image(systemName: "pencil.circle.fill").font(.system(size: 27)).symbolRenderingMode(.palette).foregroundStyle(.white, Color.accentColor) }
                                .buttonStyle(.plain).help("Choose artist profile picture")
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text(artist.name).font(.largeTitle.bold()).lineLimit(2)
                            Text("\(artist.albums.count) \(artist.albums.count == 1 ? "album" : "albums")").font(.subheadline).foregroundStyle(.secondary)
                            Button("Choose Profile Picture…") { choosingImage = true }.buttonStyle(.bordered)
                            if let imageError { Text(imageError).font(.caption).foregroundStyle(.red) }
                        }
                        Spacer(minLength: 0)
                    }
                    if artist.albums.isEmpty {
                        ContentUnavailableView("No albums found", systemImage: "square.stack", description: Text("No album metadata is available for this artist."))
                    } else {
                        LazyVGrid(columns: columns(geometry.size.width - 48), alignment: .leading, spacing: 22) {
                            ForEach(artist.albums) { album in
                                AlbumTile(album: album).contentShape(Rectangle()).onTapGesture { openAlbum(album) }
                                    .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
                                    .accessibilityAction { openAlbum(album) }
                                    .contextMenu {
                                        Button("Play Album") { if let first = album.tracks.first { playback.play(first); playback.add(Array(album.tracks.dropFirst())) } }
                                        Button("Add Album to Queue") { playback.add(album.tracks) }
                                    }
                            }
                        }
                    }
                }.padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 24)
            }
        }
        .fileImporter(isPresented: $choosingImage, allowedContentTypes: [.image], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                guard NSImage(data: data) != nil else { imageError = "That image could not be opened."; return }
                setProfileImage(data)
                imageError = nil
            } catch { imageError = "Could not load image: \(error.localizedDescription)" }
        }
    }

    @ViewBuilder private var artistImage: some View {
        if let data = artist.profileImage, let image = NSImage(data: data) {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            ZStack { Color(white: 0.22); Image(systemName: "person.fill").font(.system(size: 55)).foregroundStyle(.white.opacity(0.48)) }
        }
    }
}
