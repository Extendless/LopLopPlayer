import AppKit
import CryptoKit
import Foundation
import Observation
import Security

@MainActor @Observable final class LastFMService {
    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "lastFMEnabled")
            if isEnabled, isPlaying, let track { sendNowPlaying(track, generation: activeGeneration) }
            updateConnectionStatus()
        }
    }
    var apiKey: String {
        didSet {
            UserDefaults.standard.set(apiKey, forKey: "lastFMAPIKey")
            updateConnectionStatus()
        }
    }
    var apiSecret: String {
        didSet { LastFMCredentialStore.save(apiSecret, account: "api-secret") }
    }
    var thresholdPercent: Int {
        didSet { UserDefaults.standard.set(thresholdPercent, forKey: "lastFMThresholdPercent") }
    }
    private(set) var status = "Not connected"
    private(set) var username = ""
    private(set) var isConnecting = false
    private(set) var hasPendingAuthorization = false

    private var sessionKey: String
    private var pendingToken: String?
    private var track: Track?
    private var trackStartedAt: Date?
    private var activeGeneration = -1
    private var lastPlayedDuration = 0.0
    private var scrobbledGeneration: Int?
    private var lastNowPlayingGeneration: Int?
    private var isPlaying = false

    init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.object(forKey: "lastFMEnabled") as? Bool ?? false
        apiKey = defaults.string(forKey: "lastFMAPIKey") ?? ""
        apiSecret = LastFMCredentialStore.load(account: "api-secret")
        thresholdPercent = defaults.object(forKey: "lastFMThresholdPercent") as? Int ?? 50
        sessionKey = LastFMCredentialStore.load(account: "session-key")
        username = defaults.string(forKey: "lastFMUsername") ?? ""
        updateConnectionStatus()
    }

    var thresholdLabel: String {
        thresholdPercent == 50 ? "50% (Last.fm standard)" : "\(thresholdPercent)% of the track"
    }

    func beginAuthorization() async {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !apiSecret.isEmpty else {
            status = "Enter your Last.fm API key and shared secret first."
            return
        }
        isConnecting = true
        status = "Requesting authorization…"
        do {
            let token = try await LastFMAPI.requestToken(apiKey: key, secret: apiSecret)
            pendingToken = token
            hasPendingAuthorization = true
            var components = URLComponents(string: "https://www.last.fm/api/auth/")!
            components.queryItems = [URLQueryItem(name: "api_key", value: key), URLQueryItem(name: "token", value: token)]
            guard let url = components.url, NSWorkspace.shared.open(url) else {
                status = "Could not open Last.fm in your browser. Try again."
                isConnecting = false
                return
            }
            status = "Approve LopLop Player in your browser, then return here and finish connecting."
        } catch {
            status = error.localizedDescription
        }
        isConnecting = false
    }

    func finishAuthorization() async {
        guard let pendingToken else {
            status = "Start the Last.fm authorization first."
            return
        }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !apiSecret.isEmpty else {
            status = "Enter your Last.fm API key and shared secret first."
            return
        }
        isConnecting = true
        status = "Finishing Last.fm connection…"
        do {
            let session = try await LastFMAPI.createSession(apiKey: key, secret: apiSecret, token: pendingToken)
            sessionKey = session.key
            username = session.username
            UserDefaults.standard.set(username, forKey: "lastFMUsername")
            LastFMCredentialStore.save(sessionKey, account: "session-key")
            self.pendingToken = nil
            hasPendingAuthorization = false
            isEnabled = true
            status = "Connected as \(username)."
            if isPlaying, let track { sendNowPlaying(track, generation: activeGeneration) }
        } catch {
            status = error.localizedDescription
        }
        isConnecting = false
    }

    func disconnect() {
        sessionKey = ""
        username = ""
        pendingToken = nil
        hasPendingAuthorization = false
        LastFMCredentialStore.remove(account: "session-key")
        UserDefaults.standard.removeObject(forKey: "lastFMUsername")
        isEnabled = false
        status = "Disconnected from Last.fm."
    }

    func playbackChanged(track: Track?, isPlaying: Bool, playedDuration: Double, generation: Int) {
        if generation != activeGeneration || track?.id != self.track?.id {
            activeGeneration = generation
            self.track = track
            trackStartedAt = track == nil ? nil : Date()
            lastPlayedDuration = 0
            scrobbledGeneration = nil
            lastNowPlayingGeneration = nil
        }
        let resumed = isPlaying && !self.isPlaying
        self.isPlaying = isPlaying
        lastPlayedDuration = max(lastPlayedDuration, playedDuration)
        if isPlaying, let track, lastNowPlayingGeneration != generation || resumed {
            sendNowPlaying(track, generation: generation)
        }
        maybeScrobble()
    }

    private func sendNowPlaying(_ track: Track, generation: Int) {
        guard isEnabled, !sessionKey.isEmpty, !apiKey.isEmpty else { return }
        lastNowPlayingGeneration = generation
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = apiSecret
        let session = sessionKey
        Task {
            do {
                try await LastFMAPI.updateNowPlaying(track: track, apiKey: key, secret: secret, sessionKey: session)
                if activeGeneration == generation { status = "Connected as \(username) · now playing updated." }
            } catch {
                handleAPIError(error)
            }
        }
    }

    private func maybeScrobble() {
        guard isEnabled, !sessionKey.isEmpty, let track, let trackStartedAt,
              track.duration.isFinite, track.duration > 30,
              scrobbledGeneration != activeGeneration else { return }
        let percentageThreshold = track.duration * Double(thresholdPercent) / 100
        let threshold = thresholdPercent == 50 ? min(percentageThreshold, 240) : percentageThreshold
        guard lastPlayedDuration >= threshold else { return }
        let generation = activeGeneration
        scrobbledGeneration = generation
        let startedAt = trackStartedAt
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = apiSecret
        let session = sessionKey
        Task {
            do {
                try await LastFMAPI.scrobble(track: track, timestamp: startedAt, apiKey: key, secret: secret, sessionKey: session)
                if activeGeneration == generation { status = "Scrobbled \(track.title) · Last.fm" }
            } catch {
                handleAPIError(error)
            }
        }
    }

    private func updateConnectionStatus() {
        if !sessionKey.isEmpty, !username.isEmpty { status = "Connected as \(username)." }
        else if apiKey.isEmpty || apiSecret.isEmpty { status = "Enter your Last.fm API credentials to connect." }
        else { status = "Ready to connect to Last.fm." }
    }

    private func handleAPIError(_ error: Error) {
        if let apiError = error as? LastFMAPIError, apiError.code == 9 {
            sessionKey = ""
            LastFMCredentialStore.remove(account: "session-key")
            status = "Last.fm session expired. Connect again in Settings."
        } else {
            status = error.localizedDescription
        }
    }
}

private enum LastFMCredentialStore {
    private static let service = "com.kevyn.loplopplayer.lastfm"

    static func load(account: String) -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func save(_ value: String, account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        guard !value.isEmpty else { remove(account: account); return }
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func remove(account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

private struct LastFMSession {
    let key: String
    let username: String
}

private struct LastFMAPIError: LocalizedError {
    let code: Int
    let message: String
    var errorDescription: String? { "Last.fm error \(code): \(message)" }
}

private enum LastFMAPI {
    private static let endpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")!

    static func requestToken(apiKey: String, secret: String) async throws -> String {
        let response = try await request(["method": "auth.getToken", "api_key": apiKey], secret: secret)
        guard let token = response["token"] as? String else { throw malformedResponse }
        return token
    }

    static func createSession(apiKey: String, secret: String, token: String) async throws -> LastFMSession {
        let response = try await request(["method": "auth.getSession", "api_key": apiKey, "token": token], secret: secret)
        guard let session = response["session"] as? [String: Any],
              let key = session["key"] as? String, let username = session["name"] as? String else { throw malformedResponse }
        return LastFMSession(key: key, username: username)
    }

    static func updateNowPlaying(track: Track, apiKey: String, secret: String, sessionKey: String) async throws {
        var params = trackParameters(track)
        params["method"] = "track.updateNowPlaying"
        params["api_key"] = apiKey
        params["sk"] = sessionKey
        _ = try await request(params, secret: secret)
    }

    static func scrobble(track: Track, timestamp: Date, apiKey: String, secret: String, sessionKey: String) async throws {
        var params = trackParameters(track)
        params["method"] = "track.scrobble"
        params["api_key"] = apiKey
        params["sk"] = sessionKey
        params["timestamp"] = String(Int(timestamp.timeIntervalSince1970))
        _ = try await request(params, secret: secret)
    }

    private static func trackParameters(_ track: Track) -> [String: String] {
        var params = ["artist": track.artist, "track": track.title]
        if !track.album.isEmpty { params["album"] = track.album }
        if !track.albumArtist.isEmpty, track.albumArtist != track.artist { params["albumArtist"] = track.albumArtist }
        if let number = track.trackNumber { params["trackNumber"] = String(number) }
        if track.duration.isFinite, track.duration > 0 { params["duration"] = String(Int(track.duration.rounded())) }
        return params
    }

    private static func request(_ parameters: [String: String], secret: String) async throws -> [String: Any] {
        var signedParameters = parameters
        signedParameters["api_sig"] = signature(parameters, secret: secret)
        signedParameters["format"] = "json"
        var components = URLComponents()
        components.queryItems = signedParameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw malformedResponse }
        if let errorCode = object["error"] as? Int {
            throw LastFMAPIError(code: errorCode, message: object["message"] as? String ?? "Request failed.")
        }
        return object
    }

    private static func signature(_ parameters: [String: String], secret: String) -> String {
        let value = parameters
            .filter { $0.key != "format" && $0.key != "callback" }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)\($0.value)" }
            .joined() + secret
        return Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static var malformedResponse: LastFMAPIError {
        LastFMAPIError(code: 0, message: "Last.fm returned an unexpected response.")
    }
}
