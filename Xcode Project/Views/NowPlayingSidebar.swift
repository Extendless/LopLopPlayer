import SwiftUI

struct NowPlayingSidebar: View {
    @Bindable var playback: PlaybackController

    private var lines: [TimedLyric] { playback.current?.timedLyrics ?? [] }
    private var activeLine: Int? { LyricsParser.activeLine(in: lines, at: playback.progress) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            currentTrack
            Divider().overlay(.white.opacity(0.10))
            queueSection
                .frame(maxHeight: .infinity)
            Divider().overlay(.white.opacity(0.10))
            lyricsSection
                .frame(maxHeight: .infinity)
        }
        .padding(16)
        .frame(minWidth: 250, idealWidth: 320, maxWidth: 460, maxHeight: .infinity)
        .background(Color.black.opacity(0.14))
    }

    private var currentTrack: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Now Playing").font(.headline)
            HStack(spacing: 12) {
                ArtworkView(data: playback.current?.artwork)
                    .frame(width: 62, height: 62)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(playback.current?.title ?? "Nothing playing")
                        .font(.system(size: 14, weight: .semibold)).lineLimit(2)
                    Text(playback.current?.artist ?? "Choose a track to begin")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
    }

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Up Next").font(.headline)
                Spacer()
                Text("\(playback.queue.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if playback.queue.isEmpty {
                ContentUnavailableView("Queue is empty", systemImage: "text.badge.plus")
                    .font(.caption).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(playback.queue.enumerated()), id: \.element.id) { index, track in
                            Button { playback.play(track) } label: {
                                HStack(spacing: 9) {
                                    Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 20)
                                    ArtworkView(data: track.artwork).frame(width: 34, height: 34).clipShape(RoundedRectangle(cornerRadius: 4))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(track.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                        Text(track.artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Play \(track.title) now")
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private var lyricsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Lyrics", systemImage: "quote.bubble").font(.headline)
                Spacer()
                if !lines.isEmpty, let activeLine { Text("\(activeLine + 1) / \(lines.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
            if !lines.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                Button { playback.seek(line.time) } label: {
                                    Text(line.text)
                                        .font(.system(size: 13, weight: index == activeLine ? .semibold : .regular))
                                        .foregroundStyle(.primary.opacity(index == activeLine ? 1 : 0.52))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .id(index)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: activeLine) { _, index in
                        guard let index else { return }
                        withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(index, anchor: .center) }
                    }
                    .onAppear { if let activeLine { proxy.scrollTo(activeLine, anchor: .center) } }
                }
            } else if let lyrics = playback.current?.lyrics, !lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ScrollView { Text(lyrics).font(.system(size: 13)).lineSpacing(5).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                    .scrollIndicators(.hidden)
            } else {
                ContentUnavailableView("No embedded lyrics", systemImage: "text.quote")
                    .font(.caption).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
