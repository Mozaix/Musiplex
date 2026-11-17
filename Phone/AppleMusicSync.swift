import Foundation
import MediaPlayer
import Observation

/// Two-way playlist sync between Musiplex and the Apple Music library on
/// this iPhone.
///
/// - Apple Music → Musiplex: each of your Apple Music playlists becomes a
///   Musiplex playlist (with the songs your Mac has). Songs you add or remove
///   in Apple Music are added/removed in Musiplex.
/// - Musiplex → Apple Music: each Musiplex playlist gets an Apple Music
///   playlist, and songs you add in Musiplex are added there too (when that
///   song is in Apple Music on this iPhone).
///
/// Changes are worked out by comparing with the last sync, so edits never
/// bounce back and forth. Apple doesn't let apps remove songs from Apple
/// Music playlists, so removing a song in Musiplex leaves Apple Music as is.
@MainActor @Observable
final class AppleMusicSync {
    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "appleMusicSync")
            if enabled { authorize() }
        }
    }
    private(set) var authorized = MPMediaLibrary.authorizationStatus() == .authorized
    private(set) var denied = MPMediaLibrary.authorizationStatus() == .denied
    private(set) var lastSync: Date?
    private(set) var linkedCount = 0
    /// Songs in Musiplex playlists that aren't in Apple Music on this device.
    private(set) var notInAppleMusic = 0

    private struct Link: Codable {
        var am: UInt64
        var mp: String
        var name: String
        var lastAM: [String]
        var lastMP: [String]
    }

    @ObservationIgnored private var links: [Link] = []
    /// What the last sync saw; if nothing changed since, the next one is skipped.
    @ObservationIgnored private var lastFingerprint: Int?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var again = false
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private let fileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("applemusic-sync.json")

    /// What to sync against: the Mac's songs and playlists (nil when not connected).
    @ObservationIgnored var source: (() -> (tracks: [Track], playlists: [Playlist], device: String)?)?
    /// Sends a playlist edit to the Mac.
    @ObservationIgnored var send: ((Message) -> Void)?

    init(defaultOn: Bool) {
        enabled = UserDefaults.standard.object(forKey: "appleMusicSync") as? Bool ?? defaultOn
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode([Link].self, from: data) {
            links = saved
            linkedCount = saved.count
        }
        MPMediaLibrary.default().beginGeneratingLibraryChangeNotifications()
        NotificationCenter.default.addObserver(forName: .MPMediaLibraryDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule() }
        }
        if enabled, MPMediaLibrary.authorizationStatus() == .notDetermined { authorize() }
    }

    func authorize() {
        MPMediaLibrary.requestAuthorization { status in
            Task { @MainActor in
                self.authorized = status == .authorized
                self.denied = status == .denied || status == .restricted
                self.schedule()
            }
        }
    }

    /// Sync now even if nothing seems to have changed.
    func syncNow() {
        lastFingerprint = nil
        schedule()
    }

    /// Runs a sync shortly (several triggers in a row become one sync).
    func schedule() {
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await run()
        }
    }

    func run() async {
        guard enabled, authorized, let input = source?(), let send else { return }
        if running { again = true; return }
        // Cheap check first: skip the library scan when neither side changed.
        var hasher = Hasher()
        hasher.combine(MPMediaLibrary.default().lastModifiedDate)
        hasher.combine(input.tracks.count)
        for list in input.playlists where list.subtitle == "mine" || list.id.hasPrefix("my-") {
            hasher.combine(list.id); hasher.combine(list.name); hasher.combine(list.trackIDs)
        }
        let fingerprint = hasher.finalize()
        if fingerprint == lastFingerprint { return }
        running = true
        defer {
            running = false
            if again { again = false; schedule() }
        }

        // Musiplex songs by "same song" key.
        var byKey: [String: String] = [:]
        var trackByID: [String: Track] = [:]
        for t in input.tracks {
            trackByID[t.id] = t
            let key = songKey(title: t.title, artist: t.artist)
            if byKey[key] == nil { byKey[key] = t.id }
        }
        func key(_ item: MPMediaItem) -> String { songKey(title: item.title ?? "", artist: item.artist ?? "") }

        // Apple Music on this device.
        var libraryByKey: [String: MPMediaItem] = [:]
        for item in MPMediaQuery.songs().items ?? [] where libraryByKey[key(item)] == nil {
            libraryByKey[key(item)] = item
        }
        let amLists = (MPMediaQuery.playlists().collections as? [MPMediaPlaylist] ?? []).filter(Self.isUserPlaylist)
        let mine = input.playlists.filter { $0.subtitle == "mine" || $0.id.hasPrefix("my-") }
        let mineByID = Dictionary(mine.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let from = "Apple Music on \(input.device)"
        var next: [Link] = []

        // 1. Apple Music → Musiplex.
        for list in amLists {
            var seen = Set<String>()
            let keysNow = list.items.map(key).filter { seen.insert($0).inserted }
            let name = list.name ?? "Playlist"
            if var link = links.first(where: { $0.am == list.persistentID }) {
                if mineByID[link.mp] != nil {
                    let before = Set(link.lastAM), now = Set(keysNow)
                    let add = keysNow.filter { !before.contains($0) }.compactMap { byKey[$0] }
                    let remove = link.lastAM.filter { !now.contains($0) }.compactMap { byKey[$0] }
                    let renamed = name != link.name ? name : nil
                    if !add.isEmpty || !remove.isEmpty || renamed != nil {
                        send(Message(type: "playlist", name: renamed, ids: add, text: link.mp,
                                     removeIDs: remove, source: from))
                    }
                }
                link.lastAM = keysNow
                link.name = name
                next.append(link)
            } else {
                let ids = keysNow.compactMap { byKey[$0] }
                guard !ids.isEmpty else { continue }   // nothing in common with your Mac
                let mp = "my-am-\(list.persistentID)"
                if mineByID[mp] == nil {
                    send(Message(type: "playlist", name: name, ids: ids, text: mp, source: from))
                }
                next.append(Link(am: list.persistentID, mp: mp, name: name, lastAM: keysNow, lastMP: ids))
            }
        }

        // 2. Musiplex → Apple Music.
        var missing = 0
        for list in mine {
            if let i = next.firstIndex(where: { $0.mp == list.id }) {
                let before = Set(next[i].lastMP)
                let added = list.trackIDs.filter { !before.contains($0) }
                if !added.isEmpty, let am = amLists.first(where: { $0.persistentID == next[i].am }) {
                    let there = Set(am.items.map(key))
                    var items: [MPMediaItem] = []
                    for id in added {
                        guard let t = trackByID[id] else { continue }
                        let k = songKey(title: t.title, artist: t.artist)
                        if there.contains(k) { continue }
                        if let item = libraryByKey[k] { items.append(item) } else { missing += 1 }
                    }
                    if !items.isEmpty { try? await am.add(items) }
                }
                next[i].lastMP = list.trackIDs
            } else if let old = links.first(where: { $0.mp == list.id }) {
                // Linked before, but its Apple Music playlist is gone: leave it be.
                next.append(old)
            } else if !list.id.hasPrefix("my-am-") {
                // A Musiplex playlist Apple Music doesn't have yet: make it.
                let uuid = UUID(uuidString: String(list.id.dropFirst(3))) ?? UUID()
                let meta = MPMediaPlaylistCreationMetadata(name: list.name)
                meta.descriptionText = "From Musiplex"
                guard let am = try? await MPMediaLibrary.default().getPlaylist(with: uuid, creationMetadata: meta) else { continue }
                let there = Set(am.items.map(key))
                var items: [MPMediaItem] = []
                for id in list.trackIDs {
                    guard let t = trackByID[id] else { continue }
                    let k = songKey(title: t.title, artist: t.artist)
                    if there.contains(k) { continue }
                    if let item = libraryByKey[k] { items.append(item) } else { missing += 1 }
                }
                if !items.isEmpty { try? await am.add(items) }
                next.append(Link(am: am.persistentID, mp: list.id, name: list.name,
                                 lastAM: am.items.map(key), lastMP: list.trackIDs))
            }
        }

        links = next
        linkedCount = next.count
        lastFingerprint = fingerprint
        notInAppleMusic = missing
        lastSync = Date()
        if let data = try? JSONEncoder().encode(next) { try? data.write(to: fileURL, options: .atomic) }
    }

    /// Your own playlists: not smart/Genius ones, folders, or Apple Music's curated playlists.
    private static func isUserPlaylist(_ list: MPMediaPlaylist) -> Bool {
        let attrs = list.playlistAttributes
        if attrs.contains(.smart) || attrs.contains(.genius) { return false }
        if (list.value(forProperty: "isFolder") as? Bool) == true { return false }
        if let author = list.value(forProperty: MPMediaPlaylistPropertyAuthorDisplayName) as? String,
           author == "Apple Music" { return false }
        return true
    }
}
