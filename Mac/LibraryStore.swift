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
    /// "Surprise" (no songs: picks as it goes) and "Guess" (for this time of day).
    private(set) var forYou: [LibraryPlaylist] = []

    func setForYou(guess: [String], moment: String) {
        let guessTracks = guess.compactMap { byID[$0] }
        forYou = [
            LibraryPlaylist(id: "auto-surprise", name: "Surprise", tracks: []),
            LibraryPlaylist(id: "auto-guess", name: "Guess", tracks: guessTracks),
        ]
        guessMoment = moment
        onChange?()
    }
    private(set) var guessMoment = ""

    /// Every playlist edit, newest first (1.1, 1.2, …).
    private(set) var history: [PlaylistVersion] = []
    @ObservationIgnored private let historyURL: URL
    @ObservationIgnored var onChange: (() -> Void)?

    let artDir: URL
    private let indexURL: URL

    struct Entry: Codable, Sendable {
        var track: Track
        var path: String
        var mtime: Double
        var musicID: String? = nil
        /// The file's tags were checked for a genre (so it isn't re-read every scan).
        var genreChecked: Bool? = nil
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
        historyURL = support.appendingPathComponent("history.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: historyURL), let saved = try? decoder.decode([PlaylistVersion].self, from: data) {
            history = saved
        }
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
        var genre: String?
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
                        musicID: String(format: "%016llX", item.persistentID.uint64Value),
                        genre: item.genre.isEmpty ? nil : item.genre)
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
                    if let info = musicItems[normal] {
                        hit.track.genre = info.genre
                    } else if hit.genreChecked != true {
                        // Added before genres were read: read just the genre tag once.
                        hit.track.genre = await Self.genre(of: file.url)
                        hit.genreChecked = true
                    }
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
                          size: size, addedAt: info.added ?? added, genre: info.genre)
        return Entry(track: track, path: path, mtime: mtime, musicID: info.musicID, genreChecked: true)
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
                          ext: url.pathExtension.lowercased(), size: size, addedAt: added,
                          genre: await genre(of: url))
        return Entry(track: track, path: url.path, mtime: mtime, genreChecked: true)
    }

    /// The genre tag (ID3 TCON, iTunes ©gen / gnre, QuickTime genre).
    private nonisolated static func genre(of url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        guard let meta = try? await asset.load(.metadata) else { return nil }
        let ids: [AVMetadataIdentifier] = [.id3MetadataContentType, .iTunesMetadataUserGenre, .quickTimeMetadataGenre,
                                           .iTunesMetadataPredefinedGenre]
        for id in ids {
            guard let item = AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: id).first else { continue }
            if let text = try? await item.load(.stringValue) {
                // ID3 sometimes stores "(13)" or "(13)Pop": keep the words, drop numeric codes.
                let clean = text.replacingOccurrences(of: #"\(\d+\)"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty { return clean }
            }
        }
        return nil
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

    /// Genres looked up per artist (used for songs without a genre tag).
    @ObservationIgnored var artistGenres: [String: String] = [:] {
        didSet { if !entries.isEmpty { install(entries, save: false) } }
    }

    private func install(_ new: [Entry], save: Bool) {
        entries = new
        paths = Dictionary(new.map { ($0.track.id, $0.path) }, uniquingKeysWith: { a, _ in a })
        let looked = artistGenres
        let all = Dictionary(new.map { e -> (String, Track) in
            var t = e.track
            if t.genre == nil, let g = looked[GenreLookup.primary(t.artist)], !g.isEmpty { t.genre = g }
            return (t.id, t)
        }, uniquingKeysWith: { a, _ in a })
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
        // An Apple Music (or .m3u) playlist with the same name as one of yours is
        // the same playlist synced in from your iPhone: show it once, as yours.
        func key(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let mine = Set(userPlaylists.map { key($0.name) })
        let natural = userPlaylists.compactMap { resolve($0, editable: true) }.sorted(by: byName)
            + rawPlaylists.filter { !mine.contains(key($0.name)) }.compactMap { resolve($0, editable: false) }.sorted(by: byName)
        if order.isEmpty {
            // First time: your playlists newest-first (from the version history), then the rest.
            var created: [String: Date] = [:]
            for v in history { for c in v.changes where c.kind == .created { if let id = c.playlistID, created[id] == nil { created[id] = v.date } } }
            let mineSorted = natural.filter(\.editable).sorted { (created[$0.id] ?? .distantPast) > (created[$1.id] ?? .distantPast) }
            order = mineSorted.map(\.id) + natural.filter { !$0.editable }.map(\.id)
        }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        // Ones not placed yet (new) go first.
        playlists = natural.enumerated().sorted { a, b in
            (rank[a.element.id] ?? -1_000_000 + a.offset, a.offset) < (rank[b.element.id] ?? -1_000_000 + b.offset, b.offset)
        }.map(\.element)

        if save, let data = try? JSONEncoder().encode(Index(entries: new, playlists: rawPlaylists)) {
            try? data.write(to: indexURL, options: .atomic)
        }
        onChange?()
    }

    // MARK: Your playlists
    // Every edit says where it came from ("This Mac", a phone's name, or
    // "Apple Music on …") and is written to the version history.

    @discardableResult
    func createPlaylist(named name: String, with ids: [String] = [], id given: String? = nil,
                        source: String = "This Mac") -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = given ?? "my-" + UUID().uuidString
        if userPlaylists.contains(where: { $0.id == id }) {
            add(ids, toPlaylist: id, source: source)
            return id
        }
        let finalName = clean.isEmpty ? "New Playlist" : clean
        userPlaylists.append(Playlist(id: id, name: finalName, trackIDs: []))
        putOnTop(id)
        record([PlaylistChange(playlist: finalName, kind: .created, playlistID: id)], source: source)
        if ids.isEmpty { saveUserPlaylists() } else { add(ids, toPlaylist: id, source: source) }
        return id
    }

    /// Adds songs to the end of one of your playlists, skipping ones already in it.
    func add(_ ids: [String], toPlaylist id: String, source: String = "This Mac") {
        guard let i = userPlaylists.firstIndex(where: { $0.id == id }) else { return }
        var existing = Set(userPlaylists[i].trackIDs.map { hidden[$0] ?? $0 })
        var added: [String] = []
        for id in ids.map({ hidden[$0] ?? $0 }) where existing.insert(id).inserted {
            userPlaylists[i].trackIDs.append(id)
            added.append(id)
        }
        guard !added.isEmpty else { return }
        record([PlaylistChange(playlist: userPlaylists[i].name, kind: .added, songs: added.map(label), playlistID: id, ids: added)], source: source)
        saveUserPlaylists()
    }

    func remove(_ trackID: String, fromPlaylist id: String, source: String = "This Mac") {
        remove([trackID], fromPlaylist: id, source: source)
    }

    func remove(_ trackIDs: [String], fromPlaylist id: String, source: String = "This Mac") {
        guard let i = userPlaylists.firstIndex(where: { $0.id == id }) else { return }
        let gone = Set(trackIDs.map { hidden[$0] ?? $0 })
        let removed = userPlaylists[i].trackIDs.filter { gone.contains(hidden[$0] ?? $0) }
        guard !removed.isEmpty else { return }
        userPlaylists[i].trackIDs.removeAll { gone.contains(hidden[$0] ?? $0) }
        record([PlaylistChange(playlist: userPlaylists[i].name, kind: .removed, songs: removed.map(label), playlistID: id, ids: removed)], source: source)
        saveUserPlaylists()
    }

    func renamePlaylist(_ id: String, to name: String, source: String = "This Mac") {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let i = userPlaylists.firstIndex(where: { $0.id == id }),
              userPlaylists[i].name != clean else { return }
        let old = userPlaylists[i].name
        userPlaylists[i].name = clean
        record([PlaylistChange(playlist: clean, kind: .renamed, detail: old, playlistID: id)], source: source)
        saveUserPlaylists()
    }

    func deletePlaylist(_ id: String, source: String = "This Mac") {
        guard let list = userPlaylists.first(where: { $0.id == id }) else { return }
        userPlaylists.removeAll { $0.id == id }
        record([PlaylistChange(playlist: list.name, kind: .deleted, songs: list.trackIDs.map(label), playlistID: id, ids: list.trackIDs)], source: source)
        saveUserPlaylists()
    }

    @ObservationIgnored private var pendingRevert: Int?
    /// Called with the IDs of your playlists that just changed (for auto-push to Apple Music).
    @ObservationIgnored var onPlaylistsEdited: (([String]) -> Void)?

    // MARK: Playlist order
    // Newest playlists go to the top; drag to rearrange. The order is saved
    // and shared with your devices.

    @ObservationIgnored private var order: [String] = UserDefaults.standard.stringArray(forKey: "playlistOrder") ?? []

    /// Moves `id` so it sits just before `target` (or to the end when nil).
    func movePlaylist(_ id: String, before target: String?) {
        var ids = playlists.map(\.id)
        guard let from = ids.firstIndex(of: id) else { return }
        ids.remove(at: from)
        if let target, let to = ids.firstIndex(of: target) { ids.insert(id, at: to) } else { ids.append(id) }
        setOrder(ids)
    }

    func setOrder(_ ids: [String]) {
        order = ids
        UserDefaults.standard.set(order, forKey: "playlistOrder")
        install(entries, save: false)
    }

    private func putOnTop(_ id: String) {
        order.removeAll { $0 == id }
        order.insert(id, at: 0)
        UserDefaults.standard.set(order, forKey: "playlistOrder")
    }

    // MARK: Floaters
    // ~/Documents/Songs/Floaters is watched: anything dropped in shows up in
    // Musiplex and sits in the "Floating" playlist (shown in Settings, not the
    // sidebar) until you move it into a playlist.

    static let songsFolder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Songs", isDirectory: true)
    static let floatersFolder = songsFolder.appendingPathComponent("Floaters", isDirectory: true)

    /// Floater songs you've moved into a playlist (they leave the Floating list).
    private(set) var settled: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "settledFloaters") ?? [])
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var watchDebounce: Task<Void, Never>?

    /// Songs in the Floaters folder that haven't been moved into a playlist yet, newest first.
    var floaters: [Track] {
        let prefix = Self.floatersFolder.path + "/"
        return tracks.filter { t in
            guard !settled.contains(t.id), let path = paths[t.id] else { return false }
            return path.hasPrefix(prefix)
        }
        .sorted { $0.addedAt > $1.addedAt }
    }

    /// Moves a floating song into one of your playlists (it leaves the Floating list).
    func settle(_ ids: [String], into playlistID: String, source: String = "This Mac") {
        add(ids, toPlaylist: playlistID, source: source)
        settled.formUnion(ids)
        UserDefaults.standard.set(Array(settled), forKey: "settledFloaters")
    }

    /// Takes a song off the Floating list without adding it anywhere.
    func dismissFloater(_ id: String) {
        settled.insert(id)
        UserDefaults.standard.set(Array(settled), forKey: "settledFloaters")
    }

    /// Makes Documents/Songs/Floaters, adds Documents/Songs to the library and
    /// starts watching Floaters for new files.
    func setUpSongsFolders() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.floatersFolder, withIntermediateDirectories: true)
        if !sources.contains(Self.songsFolder.path) {
            sources.append(Self.songsFolder.path)
            UserDefaults.standard.set(sources, forKey: "sources")
            rescan()
        }
        let fd = open(Self.floatersFolder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                // Files arrive in pieces (downloads); wait until things settle.
                self?.watchDebounce?.cancel()
                self?.watchDebounce = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    self?.rescan()
                }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    /// Undoes one version: songs it added are taken out, songs it removed go
    /// back in, a rename is renamed back, a created playlist is deleted and a
    /// deleted one comes back. The undo is saved as a new version.
    @discardableResult
    func revert(_ number: Int, source: String = "This Mac") -> Bool {
        guard let version = history.first(where: { $0.number == number }) else { return false }
        // Resolve songs for versions saved before IDs were stored, by "Title — Artist".
        let byLabel = Dictionary(tracks.map { ("\($0.title) — \($0.artist)", $0.id) }, uniquingKeysWith: { a, _ in a })
        func ids(_ c: PlaylistChange) -> [String] { c.ids ?? c.songs.compactMap { byLabel[$0] } }
        func playlistID(_ c: PlaylistChange) -> String? {
            if let id = c.playlistID, userPlaylists.contains(where: { $0.id == id }) { return id }
            return userPlaylists.first { $0.name == c.playlist }?.id
        }
        // Apply as one new version.
        let before = history.first?.number
        pendingRevert = number
        let label = "\(source) · undo 1.\(number)"
        for change in version.changes.reversed() {
            switch change.kind {
            case .added:
                if let id = playlistID(change) { remove(ids(change), fromPlaylist: id, source: label) }
            case .removed:
                if let id = playlistID(change) { add(ids(change), toPlaylist: id, source: label) }
            case .renamed:
                if let id = playlistID(change), let old = change.detail { renamePlaylist(id, to: old, source: label) }
            case .created:
                if let id = playlistID(change) { deletePlaylist(id, source: label) }
            case .deleted:
                createPlaylist(named: change.playlist, with: ids(change), id: change.playlistID, source: label)
            }
            // Later changes in the same undo fold into the version just made.
            if history.first?.number != before { pendingRevert = nil }
        }
        let changed = history.first?.number != before
        pendingRevert = nil
        return changed
    }

    private func label(_ id: String) -> String {
        guard let t = byID[hidden[id] ?? id] ?? entries.first(where: { $0.track.id == id })?.track else { return "Unknown song" }
        return "\(t.title) — \(t.artist)"
    }

    /// Adds changes to the history. Quick edits from the same device (within
    /// two minutes) fold into one version instead of one version per song.
    private func record(_ changes: [PlaylistChange], source: String) {
        guard !changes.isEmpty else { return }
        let folding = pendingRevert == nil && history.first.map {
            $0.source == source && Date().timeIntervalSince($0.date) < 120 && ($0.reverts == nil || source.contains("undo"))
        } ?? false
        if folding, var last = history.first {
            for change in changes {
                if change.kind == .added || change.kind == .removed,
                   let j = last.changes.firstIndex(where: { $0.playlist == change.playlist && $0.kind == change.kind }) {
                    last.changes[j].songs += change.songs
                    last.changes[j].ids = (last.changes[j].ids ?? []) + (change.ids ?? [])
                } else {
                    last.changes.append(change)
                }
            }
            last.date = Date()
            history[0] = last
        } else {
            let next = (history.first?.number ?? 0) + 1
            history.insert(PlaylistVersion(number: next, date: Date(), source: source, changes: changes, reverts: pendingRevert), at: 0)
            pendingRevert = nil
            if history.count > 500 { history.removeLast(history.count - 500) }
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(history) { try? data.write(to: historyURL, options: .atomic) }
        let edited = changes.compactMap(\.playlistID)
        if !edited.isEmpty { onPlaylistsEdited?(edited) }
    }

    private func saveUserPlaylists() {
        if let data = try? JSONEncoder().encode(userPlaylists) { try? data.write(to: userPlaylistsURL, options: .atomic) }
        install(entries, save: false)
    }

    /// What devices get: visible songs, albums in track order, and playlists.
    var catalog: Catalog {
        Catalog(tracks: tracks,
                albums: albums.map { Playlist(id: $0.id, name: $0.title, subtitle: $0.artist, trackIDs: $0.tracks.map(\.id)) },
                playlists: forYou.map { Playlist(id: $0.id, name: $0.name, subtitle: $0.id == "auto-guess" ? "auto · \(guessMoment)" : "auto",
                                                trackIDs: $0.tracks.map(\.id)) }
                    + playlists.map { Playlist(id: $0.id, name: $0.name, subtitle: $0.editable ? "mine" : nil, trackIDs: $0.tracks.map(\.id)) },
                history: Array(history.prefix(100)))
    }
}
