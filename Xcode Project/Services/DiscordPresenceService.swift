import Darwin
import CryptoKit
import Foundation
import ImageIO
import Observation
import Security
import UniformTypeIdentifiers

@MainActor @Observable final class DiscordPresenceService {
    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "discordEnabled")
            refresh()
        }
    }
    var applicationID: String {
        didSet {
            UserDefaults.standard.set(applicationID, forKey: "discordApplicationID")
            refresh()
        }
    }
    var imageAssetKey: String {
        didSet {
            UserDefaults.standard.set(imageAssetKey, forKey: "discordImageAssetKey")
            refresh()
        }
    }
    var coverProxyURL: String {
        didSet {
            UserDefaults.standard.set(coverProxyURL, forKey: "discordCoverProxyURL")
            refresh()
        }
    }
    var coverProxyToken: String {
        didSet {
            DiscordCredentialStore.save(coverProxyToken)
            refresh()
        }
    }
    private(set) var status = "Off"
    private var currentTrack: Track?
    private var isPlaying = false
    private var progress = 0.0
    private var progressUpdatedAt = Date()
    private var refreshRevision: UInt64 = 0
    private var refreshTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private let client = DiscordIPCClient()
    private let coverRelay = DiscordCoverRelayClient()

    init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.object(forKey: "discordEnabled") as? Bool ?? true
        applicationID = defaults.string(forKey: "discordApplicationID") ?? "1564642490265509968"
        imageAssetKey = defaults.string(forKey: "discordImageAssetKey") ?? "album_cover"
        coverProxyURL = defaults.string(forKey: "discordCoverProxyURL") ?? ""
        coverProxyToken = DiscordCredentialStore.load()
        defaults.set(isEnabled, forKey: "discordEnabled")
        defaults.set(applicationID, forKey: "discordApplicationID")
        defaults.set(imageAssetKey, forKey: "discordImageAssetKey")
        defaults.set(coverProxyURL, forKey: "discordCoverProxyURL")
    }

    func playbackChanged(track: Track?, isPlaying: Bool, progress: Double) {
        currentTrack = track
        self.isPlaying = isPlaying
        self.progress = progress
        progressUpdatedAt = Date()
        refresh()
        heartbeatTask?.cancel()
        if isPlaying {
            heartbeatTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
                    guard let self, !Task.isCancelled else { return }
                    self.refresh()
                }
            }
        }
    }

    private func refresh() {
        refreshRevision &+= 1
        let revision = refreshRevision
        refreshTask?.cancel()
        guard isEnabled else {
            status = "Off"
            heartbeatTask?.cancel()
            heartbeatTask = nil
            Task { await client.clear() }
            return
        }
        guard UInt64(applicationID.trimmingCharacters(in: .whitespacesAndNewlines)) != nil else {
            status = "Enter a Discord Application ID to connect."
            Task { await client.clear() }
            return
        }
        guard let currentTrack else {
            status = "Waiting for playback."
            heartbeatTask?.cancel()
            heartbeatTask = nil
            Task { await client.clear() }
            return
        }

        let appID = applicationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let track = currentTrack
        let playing = isPlaying
        let elapsed = progress + (playing ? max(0, Date().timeIntervalSince(progressUpdatedAt)) : 0)
        let imageKey = imageAssetKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let proxyURL = coverProxyURL
        let proxyToken = coverProxyToken
        let artwork = Self.shareableArtwork(track.artwork)
        status = "Updating Discord presence…"
        refreshTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, refreshRevision == revision else { return }
            let cover = await coverRelay.publish(artwork: artwork, baseURL: proxyURL, token: proxyToken)
            guard !Task.isCancelled, refreshRevision == revision else { return }
            var result = await client.publish(applicationID: appID, track: track, isPlaying: playing, progress: elapsed, imageAssetKey: imageKey, coverImageURL: cover.url?.absoluteString)
            if let error = cover.error { result += " Cover: \(error)" }
            guard !Task.isCancelled, refreshRevision == revision else { return }
            status = result
        }
    }

    private static func shareableArtwork(_ data: Data?) -> Data? {
        guard let data,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 256
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

private enum DiscordCredentialStore {
    private static let service = "com.kevyn.musicapp.discord-cover-relay"

    static func load() -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "upload-token", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func save(_ value: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "upload-token"]
        guard !value.isEmpty else { SecItemDelete(query as CFDictionary); return }
        let data = Data(value.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}

private struct DiscordCoverRelayResult {
    var url: URL?
    var error: String?
}

private actor DiscordCoverRelayClient {
    private var cachedImageDigest: String?
    private var cachedBaseURL: String?
    private var cachedImageURL: URL?
    private var cacheExpiresAt = Date.distantPast

    func publish(artwork: Data?, baseURL: String, token: String) async -> DiscordCoverRelayResult {
        guard let artwork else { return DiscordCoverRelayResult(url: nil, error: nil) }
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmedBaseURL.isEmpty, !token.isEmpty else {
            return DiscordCoverRelayResult(url: nil, error: "set up an HTTPS cover relay in Settings to show local album art.")
        }
        guard let base = URL(string: trimmedBaseURL), base.scheme == "https", base.host != nil, base.user == nil, base.password == nil else {
            return DiscordCoverRelayResult(url: nil, error: "configure a valid HTTPS relay URL and token in Settings.")
        }

        let digest = SHA256.hash(data: artwork).map { String(format: "%02x", $0) }.joined()
        if digest == cachedImageDigest, trimmedBaseURL == cachedBaseURL, Date() < cacheExpiresAt, let cachedImageURL {
            return DiscordCoverRelayResult(url: cachedImageURL, error: nil)
        }
        guard let endpoint = URL(string: "v1/covers", relativeTo: base.appending(path: "/"))?.absoluteURL else {
            return DiscordCoverRelayResult(url: nil, error: "the relay URL is invalid.")
        }
        var request = URLRequest(url: endpoint, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.httpBody = artwork
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 201 else {
                return DiscordCoverRelayResult(url: nil, error: "the relay rejected the cover upload.")
            }
            let result = try JSONDecoder().decode(CoverUploadResponse.self, from: data)
            guard let url = URL(string: result.url), url.scheme == "https", url.host == base.host else {
                return DiscordCoverRelayResult(url: nil, error: "the relay returned an unsafe image URL.")
            }
            cachedImageDigest = digest
            cachedBaseURL = trimmedBaseURL
            cachedImageURL = url
            cacheExpiresAt = Date().addingTimeInterval(8 * 60)
            return DiscordCoverRelayResult(url: url, error: nil)
        } catch {
            return DiscordCoverRelayResult(url: nil, error: "could not reach the cover relay.")
        }
    }
}

private struct CoverUploadResponse: Decodable { var url: String }

private actor DiscordIPCClient {
    private var socket: Int32 = -1
    private var connectedApplicationID: String?
    private var connectionError = ""

    func publish(applicationID: String, track: Track, isPlaying: Bool, progress: Double, imageAssetKey: String, coverImageURL: String?) -> String {
        guard connect(applicationID: applicationID) else { return connectionError }
        var activity: [String: Any] = [
            "type": 2,
            "details": track.title,
            "state": [track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " · ")
        ]
        if let coverImageURL {
            activity["assets"] = ["large_image": coverImageURL, "large_text": track.album]
        } else if !imageAssetKey.isEmpty && imageAssetKey != "album_cover" {
            activity["assets"] = ["large_image": imageAssetKey, "large_text": track.album]
        }
        if isPlaying {
            let start = Int(Date().timeIntervalSince1970 - max(0, progress))
            var timestamps: [String: Int] = ["start": start]
            if track.duration.isFinite, track.duration > 0 {
                timestamps["end"] = start + Int(track.duration)
            }
            activity["timestamps"] = timestamps
        } else {
            activity["state"] = "Paused · \(activity["state"] as? String ?? track.artist)"
        }
        let payload: [String: Any] = [
            "cmd": "SET_ACTIVITY",
            "args": ["pid": getpid(), "activity": activity],
            "nonce": UUID().uuidString
        ]
        guard send(payload) else {
            disconnect()
            return "Discord connection lost. Reopen Discord to reconnect."
        }
        return isPlaying ? "Connected · sharing current track." : "Connected · sharing paused track."
    }

    func clear() {
        if socket >= 0 {
            _ = send(["cmd": "SET_ACTIVITY", "args": ["pid": getpid(), "activity": NSNull()], "nonce": UUID().uuidString])
        }
        disconnect()
    }

    private func connect(applicationID: String) -> Bool {
        if socket >= 0, connectedApplicationID == applicationID { return true }
        disconnect()
        var directories = ["/tmp", NSTemporaryDirectory(), "\(NSHomeDirectory())/Library/Application Support/discord"]
        if let runtimeDirectory = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"] { directories.append(runtimeDirectory) }
        var paths = directories.flatMap { directory in (0...9).map { "\(directory)/discord-ipc-\($0)" } }
        paths = Array(NSOrderedSet(array: paths)) as? [String] ?? paths
        var foundSocket = false
        for path in paths {
            let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { continue }
            var noSignal: Int32 = 1
            _ = withUnsafePointer(to: &noSignal) { Darwin.setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size)) }
            var timeout = timeval(tv_sec: 1, tv_usec: 0)
            _ = withUnsafePointer(to: &timeout) { Darwin.setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size)) }
            guard connect(descriptor, to: path) else { Darwin.close(descriptor); continue }
            foundSocket = true
            socket = descriptor
            guard let handshake = try? JSONSerialization.data(withJSONObject: ["v": 1, "client_id": applicationID]),
                  writeFrame(opcode: 0, payload: handshake),
                  let (opcode, _) = readFrame(), opcode == 1 else {
                disconnect()
                connectionError = "Found Discord, but its IPC handshake failed. Check the Application ID and restart Discord."
                continue
            }
            connectedApplicationID = applicationID
            return true
        }
        if !foundSocket { connectionError = "Discord's local IPC socket was not found. Quit and reopen the Discord desktop app, then try again." }
        return false
    }

    private func connect(_ descriptor: Int32, to path: String) -> Bool {
        let bytes = Array(path.utf8) + [0]
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes)
        }
        let length = socklen_t(MemoryLayout<UInt8>.size + MemoryLayout<sa_family_t>.size + bytes.count)
        address.sun_len = UInt8(length)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, length) == 0
            }
        }
    }

    private func send(_ message: [String: Any]) -> Bool {
        guard let payload = try? JSONSerialization.data(withJSONObject: message) else { return false }
        return writeFrame(opcode: 1, payload: payload)
    }

    private func writeFrame(opcode: UInt32, payload: Data) -> Bool {
        var frame = Data()
        var littleOpcode = opcode.littleEndian
        var littleLength = UInt32(payload.count).littleEndian
        withUnsafeBytes(of: &littleOpcode) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: &littleLength) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return false }
            var sent = 0
            while sent < bytes.count {
                let result = Darwin.write(socket, base.advanced(by: sent), bytes.count - sent)
                if result < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                sent += result
            }
            return true
        }
    }

    private func readFrame() -> (UInt32, Data)? {
        guard let header = readExactly(8) else { return nil }
        let opcode = header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian }
        let length = header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian }
        guard length <= 1_048_576, let payload = readExactly(Int(length)) else { return nil }
        return (opcode, payload)
    }

    private func readExactly(_ count: Int) -> Data? {
        var data = Data(count: count)
        let result = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return false }
            var received = 0
            while received < count {
                let amount = Darwin.read(socket, base.advanced(by: received), count - received)
                if amount < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if amount == 0 { return false }
                received += amount
            }
            return true
        }
        return result ? data : nil
    }

    private func disconnect() {
        if socket >= 0 { Darwin.close(socket) }
        socket = -1
        connectedApplicationID = nil
    }
}
