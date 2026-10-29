import SwiftUI

struct LyricsView: View {
    @Bindable var playback: PlaybackController
    private var lines: [TimedLyric] { playback.current?.timedLyrics ?? [] }
    private var activeIndex: Int? { LyricsParser.activeLine(in: lines, at: playback.progress) }
    @State private var coverTint = Color(hue: 0.69, saturation: 0.48, brightness: 0.30)

    private var lineProgress: Double {
        guard let activeIndex, lines.indices.contains(activeIndex + 1) else { return 0 }
        let start = lines[activeIndex].time
        let end = lines[activeIndex + 1].time
        guard end > start else { return 0 }
        return min(1, max(0, (playback.progress - start) / (end - start)))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ArtworkView(data: playback.current?.artwork)
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Lyrics").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.72))
                    Text(playback.current?.title ?? "Nothing playing").font(.title2.bold()).lineLimit(1)
                    Text(playback.current?.artist ?? "").font(.caption).foregroundStyle(.white.opacity(0.72)).lineLimit(1)
                }
                Spacer()
                Button { playback.showLyrics = false } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.68)) }
                    .buttonStyle(.plain).keyboardShortcut(.escape, modifiers: []).help("Close lyrics")
            }.padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 12)

            if !lines.isEmpty {
                syncedLyrics
            } else if let lyrics = playback.current?.lyrics, !lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Lyrics without timestamps", systemImage: "text.alignleft").font(.caption).foregroundStyle(.white.opacity(0.7))
                    ScrollView { Text(lyrics).font(.system(size: 21, weight: .medium)).lineSpacing(9).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                }.padding(.horizontal, 30).padding(.vertical, 24)
            } else {
                ContentUnavailableView("No embedded lyrics", systemImage: "quote.bubble", description: Text("This track doesn't contain lyrics in its audio metadata."))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            playbackControls
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                coverTint
                LinearGradient(colors: [coverTint.opacity(0.84), Color.black.opacity(0.70), Color.black.opacity(0.93)], startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [coverTint.opacity(0.55), .clear], center: .topTrailing, startRadius: 10, endRadius: 520)
            }.ignoresSafeArea()
        }
        .task(id: playback.current?.id) {
            coverTint = ArtworkColorSampler.sample(
                from: playback.current?.artwork,
                brightness: 0.27...0.55,
                minimumSaturation: 0.44,
                fallback: Color(hue: 0.69, saturation: 0.48, brightness: 0.30)
            )
        }
        .preferredColorScheme(.dark)
    }

    private var playbackControls: some View {
        VStack(spacing: 8) {
            Slider(value: Binding(get: { playback.progress }, set: { playback.seek($0) }), in: 0...max(1, playback.duration))
                .disabled(playback.current == nil)
            HStack {
                Text(playback.progress.lyricClock).frame(width: 38, alignment: .leading)
                Spacer()
                Button { playback.previous() } label: { Image(systemName: "backward.end.fill") }
                    .help("Previous track")
                Button { playback.toggle() } label: { Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 20, weight: .semibold)) }
                    .help(playback.isPlaying ? "Pause" : "Play")
                Button { playback.next() } label: { Image(systemName: "forward.end.fill") }
                    .help("Next track")
                Spacer()
                Text(playback.duration.lyricClock).frame(width: 38, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.88))
            .font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 18)
        .background(.black.opacity(0.14))
    }

    private var syncedLyrics: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 23) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Button { playback.seek(line.time) } label: {
                            Text(line.text)
                                .font(.system(size: lyricSize(for: index), weight: index == activeIndex ? .bold : .semibold, design: .rounded))
                                .foregroundStyle(Color.white.opacity(lyricOpacity(for: index)))
                                .blur(radius: lyricBlur(for: index))
                                .scaleEffect(index == activeIndex ? 1 : 0.98, anchor: .leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(line.text), \(line.time.lyricClock)")
                        .accessibilityHint("Seek to this lyric")
                        .id(index)
                    }
                }.padding(.horizontal, 34).padding(.vertical, 34)
            }
            .scrollIndicators(.hidden)
            .onChange(of: activeIndex) { _, index in
                guard let index else { return }
                withAnimation(.spring(response: 0.58, dampingFraction: 0.86)) { proxy.scrollTo(index, anchor: .center) }
            }
            .onAppear { if let activeIndex { proxy.scrollTo(activeIndex, anchor: .center) } }
            .animation(.easeInOut(duration: 0.35), value: lineProgress)
        }
    }

    private func lyricOpacity(for index: Int) -> Double {
        guard let activeIndex else { return 0.48 }
        if index == activeIndex { return 1 - (0.22 * lineProgress) }
        if index == activeIndex + 1 { return 0.22 + (0.66 * lineProgress) }
        let distance = abs(index - activeIndex)
        return max(0.09, 0.48 / Double(distance + 1))
    }

    private func lyricSize(for index: Int) -> CGFloat {
        if index == activeIndex { return 31 - (2 * lineProgress) }
        if let activeIndex, index == activeIndex + 1 { return 23 }
        return 20
    }

    private func lyricBlur(for index: Int) -> CGFloat {
        guard let activeIndex else { return 0.6 }
        if index == activeIndex { return 0 }
        if index == activeIndex + 1 { return 1.2 * (1 - lineProgress) }
        return min(2.2, CGFloat(abs(index - activeIndex)) * 0.55)
    }

}

private extension Double {
    var lyricClock: String {
        let seconds = max(0, Int(self))
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}
