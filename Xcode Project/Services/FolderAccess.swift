import AppKit
import Foundation

@MainActor final class FolderAccess {
    private enum BookmarkError: LocalizedError {
        case couldNotCreate(URL, Error, Error)

        var errorDescription: String? {
            switch self {
            case let .couldNotCreate(url, plainError, scopedError):
                return "Could not save access to \(url.lastPathComponent). Plain bookmark: \(plainError.localizedDescription). Security-scoped bookmark: \(scopedError.localizedDescription)."
            }
        }
    }

    private(set) var roots: [URL] = []
    private var bookmarks: [Data] = UserDefaults.standard.array(forKey: "musicFolderBookmarks") as? [Data] ?? []

    func restore() {
        var refreshedBookmarks: [Data] = []
        roots = bookmarks.compactMap { data in
            var stale = false
            guard let url = Self.resolve(data, stale: &stale) else { return nil }
            _ = url.startAccessingSecurityScopedResource()
            if stale, let refreshed = try? Self.makeBookmark(for: url) { refreshedBookmarks.append(refreshed) }
            else { refreshedBookmarks.append(data) }
            return url
        }
        if refreshedBookmarks != bookmarks {
            bookmarks = refreshedBookmarks
            UserDefaults.standard.set(bookmarks, forKey: "musicFolderBookmarks")
        }
    }

    func add(_ url: URL) throws {
        guard !roots.contains(where: { $0.path == url.path }) else { return }
        let data = try Self.makeBookmark(for: url)
        _ = url.startAccessingSecurityScopedResource()
        bookmarks.append(data); UserDefaults.standard.set(bookmarks, forKey: "musicFolderBookmarks")
        roots.append(url)
    }

    func remove(_ url: URL) {
        if roots.contains(where: { $0.path == url.path }) { url.stopAccessingSecurityScopedResource() }
        roots.removeAll { $0.path == url.path }; bookmarks.removeAll { data in
            var stale = false
            return Self.resolve(data, stale: &stale)?.path == url.path
        }
        UserDefaults.standard.set(bookmarks, forKey: "musicFolderBookmarks")
    }

    private static func resolve(_ data: Data, stale: inout Bool) -> URL? {
        if let scoped = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
            return scoped
        }
        stale = false
        return try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    private static func makeBookmark(for url: URL) throws -> Data {
        // This app is not sandboxed, so an ordinary bookmark is the right
        // representation and avoids the unsupported security-scope extension.
        do {
            return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch let plainError {
            do {
                return try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            } catch let scopedError {
                throw BookmarkError.couldNotCreate(url, plainError, scopedError)
            }
        }
    }

    static func chooseFolder() -> URL? {
        let panel = NSOpenPanel(); panel.title = "Choose a music folder"; panel.message = "LopLop Player needs ongoing access to scan and play files in this folder."; panel.prompt = "Choose Music Folder"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
