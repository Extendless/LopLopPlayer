import SwiftUI

struct AlbumDetail: View {
    let album: Album
    @Bindable var playback: PlaybackController
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 18) {
                ArtworkView(data: album.artwork).frame(width: 120, height: 120)
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Spacer()
                        Button(action: close) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).help("Close album details")
                    }
                    Text(album.title).font(.largeTitle.bold()).lineLimit(2)
                    Text(album.albumArtist).foregroundStyle(.secondary)
                    Text("\(album.tracks.count) tracks\(album.year.map { " · \($0)" } ?? "")").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Play") { guard let first = album.tracks.first else { return }; playback.play(first); playback.add(Array(album.tracks.dropFirst())) }
                        Button("Add to Queue") { playback.add(album.tracks) }
                    }
                }
                Spacer()
            }
            List(Array(album.tracks.enumerated()), id: \.element.id) { index, track in
                HStack {
                    Button { playback.play(track) } label: { Image(systemName: "play.fill") }
                        .buttonStyle(.plain).help("Play track")
                    Button { playback.add([track]) } label: { Image(systemName: "text.badge.plus") }
                        .buttonStyle(.plain).help("Add to queue")
                    Text(String(format: "%02d", track.trackNumber ?? index + 1)).foregroundStyle(.secondary).frame(width: 30, alignment: .trailing)
                    VStack(alignment: .leading) { Text(track.title); Text(track.artist).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Text(track.duration.clockString).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }.padding(.vertical, 3).contentShape(Rectangle()).onTapGesture(count: 2) { playback.play(track) }
            }.listStyle(.plain)
        }.padding(16).frame(minWidth: 320, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
    }
}

private extension Double { var clockString: String { "\(Int(self) / 60):\(String(format: "%02d", Int(self) % 60))" } }
