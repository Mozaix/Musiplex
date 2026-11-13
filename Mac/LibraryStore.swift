import AVFoundation
import CryptoKit
import ImageIO
import iTunesLibrary
import Observation
import UniformTypeIdentifiers

struct Album: Identifiable, Hashable {
    var id: String
    var title: String
    var artist: String
    var tracks: [Track]
    var addedAt: Double
    var artID: String? { tracks.first?.id }
}

struct Artist: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var tracks: [Track]
    var artID: String? { tracks.first?.id }
}

struct LibraryPlaylist: Identifiable, Hashable {
    var id: String
    var name: String
    var tracks: [Track]
    /// Made in Musiplex (can be edited); otherwise from Apple Music or an .m3u file.
    var editable = false
    var artID: String? { tracks.first?.id }
}

@MainActor @Observable
final class LibraryStore {
    private(set) var tracks: [Track] = []
    private(set) var albums: [Album] = []
    private(set) var recentAlbums: [Album] = []
    private(set) var artists: [Artist] = []
    private(set) var playlists: [LibraryPlaylist] = []
    private(set) var sources: [String] = UserDefaults.standard.stringArray(forKey: "sources") ?? []
    private(set) var scanning = false
    private(set) var scanStatus = ""
    /// Duplicates hidden from the library: hidden track ID → the copy that was kept.
    /// Files are never touched.
    private(set) var hidden: [String: String] = UserDefaults.standard.dictionary(forKey: "hiddenDupes") as? [String: String] ?? [:]

    @ObservationIgnored private(set) var paths: [String: String] = [:]
    @ObservationIgnored private var byID: [String: Track] = [:]
    @ObservationIgnored private var entries: [Entry] = []
    @ObservationIgnored private var rawPlaylists: [Playlist] = []
    /// Playlists you made in Musiplex. IDs start with "my-".
    private(set) var userPlaylists: [Playlist] = []
    /// Track ID → the Music app's persistent ID, for sending playlists to Apple Music.
    @ObservationIgnored private(set) var musicIDs: [String: String] = [:]
    @ObservationIgnored private let userPlaylistsURL: URL
    @ObservationIgnored var onChange: (() -> Void)?

    let artDir: URL
    private let indexURL: URL

    struct Entry: Codable, Sendable {
        var track: Track
        var path: String
        var mtime: Double
        var musicID: String? = nil
    }

    private struct Index: Codable {
        var entries: [Entry]
        var playlists: [Playlist]
    }

    nonisolated static let extensions: Set<String> = ["mp3", "m4a", "mp4", "m4v", "aac", "wav", "aif", "aiff", "flac", "mov", "caf"]
    nonisolated static let playlistExtensions: Set<String> = ["m3u", "m3u8"]

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Musiplex")
        artDir = support.appendingPathComponent("art")
        indexURL = support.appendingPathComponent("library-v2.json")
        userPlaylistsURL = support.appendingPathComponent("playlists.json")
        if let data = try? Data(contentsOf: userPlaylistsURL),
           let saved = try? JSONDecoder().decode([Playlist].self, from: data) {
            userPlaylists = saved
        }
        try? FileManager.default.createDirectory(at: artDir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL), let index = try? JSONDecoder().decode(Index.self, from: data) {
            rawPlaylists = index.playlists
            install(index.entries, save: false)
        }
        if !sources.isEmpty { rescan() }
    }

    func track(_ id: String?) -> Track? { id.flatMap { byID[$0] } }
    func url(for id: String) -> URL? { paths[id].map { URL(fileURLWithPath: $0) } }

    /// Stable track ID for a file path (normalised so the Music app's paths and
    /// the file system's agree).
    nonisolated static func id(for path: String) -> String {
        let normal = path.precomposedStringWithCanonicalMapping
        return SHA256.hash(data: Data(normal.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Sources

    static var appleMusicFolder: URL? {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
        let candidates = ["Music/Media.localized/Music", "Music/Media/Music", "Music/Media.localized",
                          "iTunes/iTunes Media/Music"]
        return candidates.map { music.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    var appleMusicConnected: Bool {
        guard let folder = Self.appleMusicFolder else { return false }
        return sources.contains(folder.path)
    }

    func add(_ urls: [URL]) {
        let new = urls.map(\.path).filter { !sources.contains($0) }
        guard !new.isEmpty else { return }
        sources += new
        UserDefaults.standard.set(sources, forKey: "sources")
        rescan()
    }

    func remove(source: String) {
        sources.removeAll { $0 == source }
        UserDefaults.standard.set(sources, forKey: "sources")
        rescan()
    }

    // MARK: Duplicates

    func findDuplicates() -> [String: String] { Musiplex.findDuplicates(in: tracks) }

    /// Hides duplicates from Musiplex. The files themselves are left alone.
    func hideDuplicates(_ dupes: [String: String]) {
        hidden.merge(dupes) { _, new in new }
        UserDefaults.standard.set(hidden, forKey: "hiddenDupes")
        install(entries, save: false)
    }

    func restoreHidden() {
        hidden = [:]
        UserDefaults.standard.removeObject(forKey: "hiddenDupes")
        install(entries, save: false)
    }

    // MARK: Scanning

    /// What the Music app knows about a file, so we don't have to open it.
    private struct MusicItem: Sendable {
        var title: String
        var artist: String
        var album: String
        var duration: Double
        var added: Double?
        var artwork: Data?
        var musicID: String
    }

    func rescan() {
        guard !scanning else { return }
        scanning = true
        scanStatus = "Scanning…"
        let sources = sources
        let useMusicApp = appleMusicConnected
        let known = Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let artDir = artDir
        Task.detached(priority: .utility) {
            let fm = FileManager.default

            // 1. The Apple Music library: metadata, files kept outside its folder, playlists.
            var musicItems: [String: MusicItem] = [:]
            var musicOrder: [String] = []
            var musicPlaylists: [(name: String, paths: [String])] = []
            if useMusicApp, let lib = try? ITLibrary(apiVersion: "1.0") {
                for item in lib.allMediaItems {
                    guard let url = item.location, Self.extensions.contains(url.pathExtension.lowercased()) else { continue }
                    let path = url.path
                    let needsArt = item.hasArtworkAvailable && known[path] == nil
                        && !fm.fileExists(atPath: artDir.appendingPathComponent("\(Self.id(for: path)).jpg").path)
                    musicItems[path.precomposedStringWithCanonicalMapping] = MusicItem(
                        title: item.title, artist: item.artist?.name ?? "Unknown Artist",
                        album: item.album.title ?? "Unknown Album", duration: Double(item.totalTime) / 1000,
                        added: item.addedDate?.timeIntervalSince1970,
                        artwork: needsArt ? item.artwork?.imageData : nil,
                        musicID: String(format: "%016llX", item.persistentID.uint64Value))
                    musicOrder.append(path)
                }
                for list in lib.allPlaylists where !list.isMaster && list.distinguishedKind == .kindNone
                    && list.kind != .folder && list.isVisible && !list.items.isEmpty {
                    musicPlaylists.append((list.name, list.items.compactMap { $0.location?.path }))
                }
            }

            // 2. Files in the imported folders, plus the Music app's own files.
            var files: [(url: URL, root: String?)] = []
            var m3us: [URL] = []
            for source in sources {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: source, isDirectory: &isDir) else { continue }
                let root = URL(fileURLWithPath: source)
                if isDir.boolValue {
                    let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                               options: [.skipsHiddenFiles, .skipsPackageDescendants])
                    while let url = walker?.nextObject() as? URL {
                        let ext = url.pathExtension.lowercased()
                        if Self.extensions.contains(ext) { files.append((url, source)) }
                        else if Self.playlistExtensions.contains(ext) { m3us.append(url) }
                    }
                } else {
                    let ext = root.pathExtension.lowercased()
                    if Self.extensions.contains(ext) { files.append((root, nil)) }
                    else if Self.playlistExtensions.contains(ext) { m3us.append(root) }
                }
            }
            for path in musicOrder { files.append((URL(fileURLWithPath: path), nil)) }

            var result: [Entry] = []
            var seen = Set<String>()
            var fresh = 0
            for (n, file) in files.enumerated() {
                let path = file.url.path
                let normal = path.precomposedStringWithCanonicalMapping
                guard seen.insert(normal).inserted else { continue }
                guard let values = try? file.url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .creationDateKey])
                else { continue }
                let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
                if var hit = known[path], hit.mtime == mtime {
                    hit.musicID = musicItems[normal]?.musicID ?? hit.musicID
                    result.append(hit)
                    continue
                }
                let size = Int64(values.fileSize ?? 0)
                let added = values.creationDate?.timeIntervalSince1970 ?? mtime
                let entry: Entry?
                if let info = musicItems[normal] {
                    entry = Self.entry(from: info, path: path, mtime: mtime, size: size, added: added, artDir: artDir)
                } else {
                    entry = await Self.read(file.url, root: file.root, mtime: mtime, size: size, added: added, artDir: artDir)
                }
                if let entry {
                    result.append(entry)
                    fresh += 1
                    if fresh % 60 == 0 {
                        let partial = result
                        let status = "Importing \(n + 1) of \(files.count)"
                        await MainActor.run {
                            self.scanStatus = status
                            self.install(partial, save: false)
                        }
                    }
                }
            }

            // 3. Playlists: Apple Music first, then .m3u files in imported folders.
            var lists: [Playlist] = []
            for (name, paths) in musicPlaylists {
                lists.append(Playlist(id: "am-" + Self.id(for: name), name: name, trackIDs: paths.map(Self.id(for:))))
            }
            for url in m3us {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let dir = url.deletingLastPathComponent()
                let ids = text.split(whereSeparator: \.isNewline).compactMap { raw -> String? in
                    let line = raw.trimmingCharacters(in: .whitespaces)
                    guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
                    let target: URL
                    if line.hasPrefix("/") {
                        target = URL(fileURLWithPath: line)
                    } else if let url = URL(string: line), url.isFileURL {
                        target = url
                    } else {
                        target = dir.appendingPathComponent(line)
                    }
                    return Self.id(for: target.standardizedFileURL.path)
                }
                if !ids.isEmpty {
                    lists.append(Playlist(id: "m3u-" + Self.id(for: url.path),
                                          name: url.deletingPathExtension().lastPathComponent, trackIDs: ids))
                }
            }

            let final = result
            let finalLists = lists
            await MainActor.run {
                self.rawPlaylists = finalLists
                self.install(final, save: true)
                self.scanning = false
                self.scanStatus = ""
            }
        }
    }

    private nonisolated static func entry(from info: MusicItem, path: String, mtime: Double, size: Int64,
                                          added: Double, artDir: URL) -> Entry {
        let id = id(for: path)
        if let art = info.artwork { writeThumbnail(art, to: artDir.appendingPathComponent("\(id).jpg")) }
        let track = Track(id: id, title: info.title, artist: info.artist, album: info.album,
                          duration: info.duration, ext: (path as NSString).pathExtension.lowercased(),
                          size: size, addedAt: info.added ?? added)
        return Entry(track: track, path: path, mtime: mtime, musicID: info.musicID)
    }

    private nonisolated static func read(_ url: URL, root: String?, mtime: Double, size: Int64,
                                         added: Double, artDir: URL) async -> Entry? {
        let asset = AVURLAsset(url: url)
        guard let playable = try? await asset.load(.isPlayable), playable,
              let duration = try? await asset.load(.duration) else { return nil }
        let meta = (try? await asset.load(.commonMetadata)) ?? []

        func string(_ key: AVMetadataKey) async -> String? {
            guard let item = AVMetadataItem.metadataItems(from: meta, withKey: key, keySpace: .common).first,
                  let value = try? await item.load(.stringValue) else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        // Fall back to the Artist/Album/Song folder layout the Music app uses.
        var folderArtist: String?, folderAlbum: String?
        if let root {
            let rel = url.path.dropFirst(root.count).split(separator: "/").map(String.init)
            if rel.count >= 3 {
                folderArtist = rel[rel.count - 3]
                folderAlbum = rel[rel.count - 2]
            }
        }

        let id = id(for: url.path)
        // No title tag: use the file name, minus a leading track number ("01 ", "1-02 ").
        let fileTitle = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: #"^(\d+-)?\d{1,3}[\s._-]+(?=\S)"#, with: "", options: .regularExpression)
        let title = await string(.commonKeyTitle) ?? fileTitle
        let artist = await string(.commonKeyArtist) ?? folderArtist ?? "Unknown Artist"
        let album = await string(.commonKeyAlbumName) ?? folderAlbum ?? "Unknown Album"

        if !FileManager.default.fileExists(atPath: artDir.appendingPathComponent("\(id).jpg").path),
           let item = AVMetadataItem.metadataItems(from: meta, withKey: AVMetadataKey.commonKeyArtwork, keySpace: .common).first,
           let data = try? await item.load(.dataValue) {
            writeThumbnail(data, to: artDir.appendingPathComponent("\(id).jpg"))
        }

        let seconds = duration.seconds
        let track = Track(id: id, title: title, artist: artist, album: album,
                          duration: seconds.isFinite ? seconds : 0,
                          ext: url.pathExtension.lowercased(), size: size, addedAt: added)
        return Entry(track: track, path: url.path, mtime: mtime)
    }

    private nonisolated static func writeThumbnail(_ data: Data, to url: URL) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 640,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, thumb, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    private func install(_ new: [Entry], save: Bool) {
        entries = new
        paths = Dictionary(new.map { ($0.track.id, $0.path) }, uniquingKeysWith: { a, _ in a })
        let all = Dictionary(new.map { ($0.track.id, $0.track) }, uniquingKeysWith: { a, _ in a })
        byID = all
        // Ignore hides whose kept copy has gone missing, so a song is never lost.
        let hidden = self.hidden.filter { all[$0.value] != nil }
        tracks = all.values.filter { hidden[$0.id] == nil }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        let paths = paths
        func inFileOrder(_ list: [Track]) -> [Track] {
            list.sorted { (paths[$0.id] ?? "").localizedStandardCompare(paths[$1.id] ?? "") == .orderedAscending }
        }

        let albumGroups = Dictionary(grouping: tracks) { t in
            t.album == "Unknown Album" ? "?|\(t.artist)" : t.album.lowercased()
        }
        albums = albumGroups.map { key, list in
            let names = Set(list.map(\.artist))
            return Album(id: key, title: list[0].album,
                         artist: names.count == 1 ? list[0].artist : "Various Artists",
                         tracks: inFileOrder(list), addedAt: list.map(\.addedAt).max() ?? 0)
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        recentAlbums = albums.sorted { $0.addedAt > $1.addedAt }

        artists = Dictionary(grouping: tracks, by: \.artist).map { Artist(name: $0, tracks: inFileOrder($1)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        musicIDs = Dictionary(new.compactMap { e in e.musicID.map { (e.track.id, $0) } }, uniquingKeysWith: { a, _ in a })

        // Playlists point at the kept copy of any hidden duplicate. Yours come first.
        func resolve(_ list: Playlist, editable: Bool) -> LibraryPlaylist? {
            var seen = Set<String>()
            let items = list.trackIDs.compactMap { id -> Track? in
                let real = hidden[id] ?? id
                guard seen.insert(real).inserted else { return nil }
                return all[real]
            }
            if items.isEmpty, !editable { return nil }
            return LibraryPlaylist(id: list.id, name: list.name, tracks: items, editable: editable)
        }
        let byName: (LibraryPlaylist, LibraryPlaylist) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        playlists = userPlaylists.compactMap { resolve($0, editable: true) }.sorted(by: byName)
            + rawPlaylists.compactMap { resolve($0, editable: false) }.sorted(by: byName)

        if save, let data = try? JSONEncoder().encode(Index(entries: new, playlists: rawPlaylists)) {
            try? data.write(to: indexURL, options: .atomic)
        }
        onChange?()
    }

    // MARK: Your playlists

    @discardableResult
    func createPlaylist(named name: String, with ids: [String] = []) -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = "my-" + UUID().uuidString
        userPlaylists.append(Playlist(id: id, name: clean.isEmpty ? "New Playlist" : clean, trackIDs: []))
        if ids.isEmpty { saveUserPlaylists() } else { add(ids, toPlaylist: id) }
        return id
    }

    /// Adds songs to the end of one of your playlists, skipping ones already in it.
    func add(_ ids: [String], toPlaylist id: String) {
        guard let i = userPlaylists.firstIndex(where: { $0.id == id }) else { return }
        var existing = Set(userPlaylists[i].trackIDs)
        for id in ids.map({ hidden[$0] ?? $0 }) where existing.insert(id).inserted {
            userPlaylists[i].trackIDs.append(id)
        }
        saveUserPlaylists()
    }

    func remove(_ trackID: String, fromPlaylist id: String) {
        guard let i = userPlaylists.firstIndex(where: { $0.id == id }) else { return }
        userPlaylists[i].trackIDs.removeAll { $0 == trackID || hidden[$0] == trackID }
        saveUserPlaylists()
    }

    func renamePlaylist(_ id: String, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let i = userPlaylists.firstIndex(where: { $0.id == id }) else { return }
        userPlaylists[i].name = clean
        saveUserPlaylists()
    }

    func deletePlaylist(_ id: String) {
        userPlaylists.removeAll { $0.id == id }
        saveUserPlaylists()
    }

    private func saveUserPlaylists() {
        if let data = try? JSONEncoder().encode(userPlaylists) { try? data.write(to: userPlaylistsURL, options: .atomic) }
        install(entries, save: false)
    }

    /// What devices get: visible songs, albums in track order, and playlists.
    var catalog: Catalog {
        Catalog(tracks: tracks,
                albums: albums.map { Playlist(id: $0.id, name: $0.title, subtitle: $0.artist, trackIDs: $0.tracks.map(\.id)) },
                playlists: playlists.map { Playlist(id: $0.id, name: $0.name, subtitle: nil, trackIDs: $0.tracks.map(\.id)) })
    }
}
