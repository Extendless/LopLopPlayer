import SwiftUI

struct NowPlayingBar: View {
    @Bindable var playback: PlaybackController
    var body: some View {
        VStack(spacing: 6) {
            if playback.current != nil { Slider(value: Binding(get: { playback.progress }, set: { playback.seek($0) }), in: 0...max(1, playback.duration)).controlSize(.mini) }
            HStack(spacing: 14) {
                Button { playback.showLyrics = true } label: {
                    ArtworkView(data: playback.current?.artwork).frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 4))
                }.buttonStyle(.plain).disabled(playback.current == nil).help("Open lyrics")
                    .accessibilityLabel("Open lyrics for current track")
                VStack(alignment: .leading, spacing: 3) {
                    Text(playback.current?.artist ?? "Nothing playing").font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(playback.current?.title ?? "Choose an album to begin").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }.frame(minWidth: 100, maxWidth: 280, alignment: .leading)
                Spacer(minLength: 4)
                Button { playback.previous() } label: { Image(systemName: "backward.end.fill") }.help("Previous")
                Button { playback.toggle() } label: { Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 23)) }.help(playback.isPlaying ? "Pause" : "Play")
                Button { playback.next() } label: { Image(systemName: "forward.end.fill") }.help("Next")
                Spacer(minLength: 4)
                Button { playback.showLyrics = true } label: { Image(systemName: "quote.bubble") }
                    .help("Show embedded lyrics")
                    .accessibilityLabel("Show lyrics")
                    .disabled(playback.current == nil)
                Button { playback.toggleFavorite() } label: { Image(systemName: playback.isFavorite ? "heart.fill" : "heart") }.help("Favorite current track")
                Slider(value: $playback.volume, in: 0...1).frame(width: 95).help("Volume")
            }.buttonStyle(.plain)
            if let error = playback.error { Text(error).font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading) }
        }.padding(.horizontal, 14).padding(.vertical, 8).background(Color(white: 0.30))
    }
}

private extension Double { var clockString: String { guard isFinite else { return "0:00" }; return "\(Int(self) / 60):\(String(format: "%02d", Int(self) % 60))" } }
