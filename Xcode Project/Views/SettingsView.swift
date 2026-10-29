import SwiftUI

struct SettingsView: View {
    @Bindable var store: LibraryStore
    @AppStorage("skipInterval") private var skipInterval = 10.0
    @AppStorage("skipWithOption") private var skipWithOption = false
    @Bindable var discordPresence: DiscordPresenceService
    @Bindable var lastFM: LastFMService
    var body: some View {
        Form {
            Section("Music folders") {
                if store.folders.roots.isEmpty { Text("No folders selected").foregroundStyle(.secondary) }
                ForEach(store.folders.roots, id: \.path) { folder in
                    HStack { Image(systemName: "folder"); Text(folder.lastPathComponent); Spacer(); Button("Remove") { store.removeFolder(folder) }.buttonStyle(.borderless) }
                }
                HStack { Button("Add Folder…") { store.chooseFolder() }; Button("Rescan Now") { Task { await store.rescan() } }; if store.isScanning { ProgressView().controlSize(.small) } }
                Text(store.scanStatus).font(.caption).foregroundStyle(.secondary)
            }
            Section("Playback") {
                Picker("Skip interval", selection: $skipInterval) { Text("5 seconds").tag(5.0); Text("10 seconds").tag(10.0); Text("15 seconds").tag(15.0); Text("30 seconds").tag(30.0) }
                Toggle("Require Option with skip keys", isOn: $skipWithOption)
                Text("\(skipWithOption ? "Option + " : "")← / → seeks by interval · Shift + ← / → changes tracks · Shift + ↑ / ↓ changes volume.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Last.fm") {
                Toggle("Enable scrobbling", isOn: $lastFM.isEnabled)
                TextField("Last.fm API key", text: $lastFM.apiKey).textFieldStyle(.roundedBorder)
                SecureField("Last.fm shared secret", text: $lastFM.apiSecret).textFieldStyle(.roundedBorder)
                Link("Get Last.fm API credentials", destination: URL(string: "https://www.last.fm/api/account/create")!)
                HStack {
                    if lastFM.hasPendingAuthorization {
                        Button("Finish Last.fm Connection") { Task { await lastFM.finishAuthorization() } }
                            .disabled(lastFM.isConnecting)
                    } else {
                        Button(lastFM.username.isEmpty ? "Connect with Last.fm" : "Reconnect Last.fm") { Task { await lastFM.beginAuthorization() } }
                            .disabled(lastFM.isConnecting || lastFM.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || lastFM.apiSecret.isEmpty)
                    }
                    if !lastFM.username.isEmpty { Button("Disconnect") { lastFM.disconnect() }.buttonStyle(.borderless) }
                    if lastFM.isConnecting { ProgressView().controlSize(.small) }
                }
                Picker("Scrobble after", selection: $lastFM.thresholdPercent) {
                    Text("50% · Last.fm standard").tag(50)
                    Text("60%").tag(60)
                    Text("75%").tag(75)
                    Text("100% · track finished").tag(100)
                }
                Text("Last.fm requires at least half a track or 4 minutes of playback, whichever comes first. Higher thresholds delay submission; tracks shorter than 30 seconds are not scrobbled. Your API secret and session are stored in Keychain.").font(.caption).foregroundStyle(.secondary)
                Text(lastFM.status).font(.caption).foregroundStyle(lastFM.username.isEmpty ? .orange : .secondary)
            }
            Section("Discord Rich Presence") {
                Toggle("Enable Discord presence", isOn: $discordPresence.isEnabled)
                TextField("Discord Application ID", text: $discordPresence.applicationID)
                    .textFieldStyle(.roundedBorder)
                TextField("Cover relay HTTPS URL", text: $discordPresence.coverProxyURL)
                    .textFieldStyle(.roundedBorder)
                SecureField("Cover relay upload token", text: $discordPresence.coverProxyToken)
                    .textFieldStyle(.roundedBorder)
                TextField("Fallback Discord image asset key", text: $discordPresence.imageAssetKey)
                    .textFieldStyle(.roundedBorder)
                Text("To show local album covers, configure a LopLop cover relay over HTTPS. Covers are reduced to 256 px and held in relay memory for up to 10 minutes. The fallback image key must match an image uploaded to your Discord application. Track title, artist, album, and playback time are shared with Discord; audio and file paths are not.").font(.caption).foregroundStyle(.secondary)
                Text(discordPresence.status).font(.caption).foregroundStyle(discordPresence.status.contains("set up") || discordPresence.status.contains("rejected") || discordPresence.status.contains("could not") ? .orange : .secondary)
            }
            Section("Audio formats") { Text("MP3, M4A, M4B, AAC, WAV, AIFF, CAF, ALAC, and FLAC (when supported by the installed macOS AVFoundation codecs). Metadata comes from embedded common tags.").font(.caption).foregroundStyle(.secondary) }
        }.formStyle(.grouped).padding(20).frame(width: 560, height: 710)
    }
}
