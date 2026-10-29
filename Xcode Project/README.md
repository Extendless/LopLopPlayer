# LopLop Player

Native macOS 14+ music player built with SwiftUI and system frameworks. The repository was empty when work began, so Swift Package Manager provides the build target and no third-party dependencies are used.

## Build and run

Run `./script/build_and_run.sh` to compile and launch the generated `dist/LopLop Player.app`. Run `swift test` for the deterministic model tests.

## Visual direction

The reference screenshot is a dark charcoal window with a quiet Albums heading, evenly spaced square artwork, bottom dark fades for white album/artist text, and a persistent gray player strip. This app carries those cues into adaptive native album and artist grids, adds keyboard reachable album and artist detail pages, and keeps player controls anchored at the bottom. Artist pages show a circular profile image, album count, and the artist's albums. Users can choose a local image; a resized copy is stored in app preferences and follows the normalized artist name. The artwork itself is read from the user's library; the screenshot's unrelated text/art are not included.

## Architecture and supported audio

- `Models/Track.swift`: stable path-based track identity and album grouping.
- `Services/FolderAccess.swift`, `LibraryScanner.swift`, `FolderMonitor.swift`: security scoped directory access, background metadata scan, and debounced folder change refresh.
- `Stores/LibraryStore.swift`, `Services/PlaybackController.swift`: library state, queue, playback, progress, volume, and favorites.
- `Views/`: album and artist grids/details, command palette with track/album/artist results, settings, and persistent player.

Scannable extensions are MP3, M4A, M4B, AAC, WAV, AIFF, CAF, ALAC, and FLAC. AVFoundation/AVPlayer handles decoding when the installed macOS codec supports the particular file; malformed or unsupported files are skipped. Title, artist, album, album artist, duration, track/disc number, genre, year, embedded artwork, and embedded lyrics are read from AVFoundation. Timestamped ID3 synchronized lyrics and LRC-formatted embedded lyrics follow playback in the lyrics panel, which can be opened from the player artwork, lyrics button, or command palette. The panel uses a cover-derived color wash and fades nearby lines around the active lyric; plain embedded lyrics remain readable without line highlighting. Missing tags fall back to file/folder names and “Unknown Artist.”

## Current limitations

Last.fm scrobbling is not implemented. Discord Rich Presence publishes the current track and playback timestamps over the local Discord desktop IPC connection. To show embedded local covers, run the self-hosted relay in `discord-cover-relay/` behind an HTTPS reverse proxy. Set `DISCORD_COVER_TOKEN` to a random secret, `PUBLIC_BASE_URL` to the relay's public HTTPS origin, and run `python3 server.py`; then enter that URL and secret under Settings > Discord Rich Presence. The relay stores at most 128 resized covers in memory for up to 10 minutes and requires the secret for uploads; Discord fetches covers from short-lived random URLs. Discord may cache images independently. Without a relay, the configured Developer Portal art asset is used as a fallback. Favorites use path identity and therefore do not follow moved files. Queue/current playback restoration, choosing arbitrary shortcut keys, and broad integration/UI tests remain future work; Settings can change the skip interval and toggle Option as a modifier. Folder bookmarks are security scoped, but bookmark access/revocation recovery is basic.
