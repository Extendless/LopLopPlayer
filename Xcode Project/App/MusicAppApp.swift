import AppKit
import SwiftUI

@main struct MusicAppApp: App {
    @NSApplicationDelegateAdaptor(MusicAppDelegate.self) private var appDelegate
    @State private var library = LibraryStore()
    @State private var discordPresence = DiscordPresenceService()
    @State private var lastFM = LastFMService()
    @AppStorage("skipWithOption") private var skipWithOption = false
    private var skipModifiers: EventModifiers { skipWithOption ? .option : [] }
    var body: some Scene {
        WindowGroup {
            ContentView(store: library, discordPresence: discordPresence, lastFM: lastFM).frame(minWidth: 720, minHeight: 520)
        }
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("Playback") {
                Button(library.playback.isPlaying ? "Pause" : "Play") { library.playback.toggle() }.keyboardShortcut(.space, modifiers: [])
                Button("Previous Track") { library.playback.previous() }.keyboardShortcut(.leftArrow, modifiers: [.command])
                Button("Next Track") { library.playback.next() }.keyboardShortcut(.rightArrow, modifiers: [.command])
                Button("Previous Track") { library.playback.previous() }.keyboardShortcut(.leftArrow, modifiers: [.shift])
                Button("Next Track") { library.playback.next() }.keyboardShortcut(.rightArrow, modifiers: [.shift])
                Button("Skip Back") { library.playback.skip(-UserDefaults.standard.double(forKey: "skipInterval").nonzeroOr(10)) }.keyboardShortcut(.leftArrow, modifiers: skipModifiers)
                Button("Skip Forward") { library.playback.skip(UserDefaults.standard.double(forKey: "skipInterval").nonzeroOr(10)) }.keyboardShortcut(.rightArrow, modifiers: skipModifiers)
                Button("Raise Volume") { library.playback.volume = min(1, library.playback.volume + 0.05) }.keyboardShortcut(.upArrow, modifiers: .shift)
                Button("Lower Volume") { library.playback.volume = max(0, library.playback.volume - 0.05) }.keyboardShortcut(.downArrow, modifiers: .shift)
                Button("Add Current Album to Queue") { if let album = library.selectedAlbum { library.playback.add(album.tracks) } }
                Button(library.playback.isFavorite ? "Unfavorite Current Track" : "Favorite Current Track") { library.playback.toggleFavorite() }
            }
            CommandGroup(after: .appInfo) { SettingsLink() }
            CommandGroup(after: .toolbar) {
                Button("Command Palette…") { library.showPalette = true }.keyboardShortcut("p", modifiers: .command)
                Button("Rescan Library") { Task { await library.rescan() } }
            }
        }
        Settings { SettingsView(store: library, discordPresence: discordPresence, lastFM: lastFM) }
    }
}

@MainActor
private final class MusicAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

private extension Double { func nonzeroOr(_ fallback: Double) -> Double { self == 0 ? fallback : self } }
