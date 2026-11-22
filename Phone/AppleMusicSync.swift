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
///   playlist, and its songs are added there too: from Apple Music on this
///   iPhone, or else found in the Apple Music catalog (needs a subscription).
///   Songs that couldn't be added yet are retried on later syncs.
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
        /// Songs you removed from the Apple Music playlist yourself: never put back.
        var removed: [String]? = nil
    }

    @ObservationIgnored private var links: [Link] = []
    /// What the last sync saw; if nothing changed since, the next one is skipped.
    @ObservationIgnored private var lastFingerprint: Int?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var catalogTried: [String: Date] = [:]
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

        // Looser match for the same song tagged a bit differently on each side:
        // "Song (feat. X)" vs "Song", "A, B" vs "A & B".
        var libraryByLoose: [String: MPMediaItem] = [:]
        for item in MPMediaQuery.songs().items ?? [] {
            let k = Self.looseKey(item.title ?? "", item.artist ?? "")
            if libraryByLoose[k] == nil { libraryByLoose[k] = item }
        }
        func loose(_ t: Track) -> MPMediaItem? { libraryByLoose[Self.looseKey(t.title, t.artist)] }

        // 1. Apple Music → Musiplex.
        for list in amLists {
            var seen = Set<String>()
            let keysNow = list.items.map(key).filter { seen.insert($0).inserted }
            let name = list.name ?? "Playlist"
            if var link = links.first(where: { $0.am == list.persistentID }) {
                if mineByID[link.mp] != nil {
                    let before = Set(link.lastAM), now = Set(keysNow)
                    var removed = Set(link.removed ?? [])
                    removed.formUnion(link.lastAM.filter { !now.contains($0) })
                    removed.subtract(keysNow)
                    link.removed = Array(removed)
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
                // Already have a Musiplex playlist with this name (e.g. one Musiplex
                // pushed to Apple Music)? Link to it instead of making a twin.
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if let same = mine.first(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == trimmed }),
                   !next.contains(where: { $0.mp == same.id }) {
                    let missing = ids.filter { !same.trackIDs.contains($0) }
                    if !missing.isEmpty { send(Message(type: "playlist", ids: missing, text: same.id, source: from)) }
                    next.append(Link(am: list.persistentID, mp: same.id, name: name, lastAM: keysNow, lastMP: same.trackIDs))
                    continue
                }
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
                // Every song in the Musiplex playlist that the Apple Music one lacks, not just
                // ones added since last time: songs that weren't on this iPhone yet are retried.
                // Songs you removed in Apple Music stay out, unless you add them again in Musiplex.
                let before = Set(next[i].lastMP)
                var removed = Set(next[i].removed ?? [])
                for id in list.trackIDs where !before.contains(id) {
                    if let t = trackByID[id] { removed.remove(songKey(title: t.title, artist: t.artist)) }
                }
                next[i].removed = Array(removed)
                if let am = amLists.first(where: { $0.persistentID == next[i].am }) {
                    let there = Set(am.items.map(key))
                    var items: [MPMediaItem] = []
                    var catalog: [Track] = []
                    for id in list.trackIDs {
                        guard let t = trackByID[id] else { continue }
                        let k = songKey(title: t.title, artist: t.artist)
                        if there.contains(k) || removed.contains(k) { continue }
                        if let item = libraryByKey[k] ?? loose(t) { items.append(item) } else { catalog.append(t) }
                    }
                    if !items.isEmpty { try? await am.add(items) }
                    missing += await addFromCatalog(catalog, to: am)
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
                var catalog: [Track] = []
                for id in list.trackIDs {
                    guard let t = trackByID[id] else { continue }
                    let k = songKey(title: t.title, artist: t.artist)
                    if there.contains(k) { continue }
                    if let item = libraryByKey[k] ?? loose(t) { items.append(item) } else { catalog.append(t) }
                }
                if !items.isEmpty { try? await am.add(items) }
                missing += await addFromCatalog(catalog, to: am)
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

    static func looseKey(_ title: String, _ artist: String) -> String {
        let cut = title.range(of: #"\s*(\(|\[| - | feat\.? | ft\.? ).*$"#, options: [.regularExpression, .caseInsensitive])
        let base = cut.map { String(title[..<$0.lowerBound]) } ?? title
        let lead = artist.lowercased().range(of: #",| & | x | feat\.? | ft\.? | and "#, options: .regularExpression)
        let main = lead.map { String(artist.lowercased()[..<$0.lowerBound]) } ?? artist
        return songKey(title: base, artist: main)
    }

    /// Songs not in Apple Music on this iPhone: find them in the Apple Music catalog
    /// (Apple's free search) and add them by their store ID. Needs an Apple Music
    /// subscription. Returns how many still couldn't be added.
    private func addFromCatalog(_ tracks: [Track], to playlist: MPMediaPlaylist) async -> Int {
        guard !tracks.isEmpty else { return 0 }
        var failed = 0
        let country = Locale.current.region?.identifier ?? "US"
        let now = Date()
        for t in tracks.prefix(25) {
            // Couldn't add it lately: don't ask Apple again for a few hours.
            let tk = Self.looseKey(t.title, t.artist)
            if let when = catalogTried[tk], now.timeIntervalSince(when) < 6 * 3600 { failed += 1; continue }
            var comps = URLComponents(string: "https://itunes.apple.com/search")!
            comps.queryItems = [.init(name: "term", value: "\(t.title) \(t.artist)"), .init(name: "entity", value: "song"),
                                .init(name: "limit", value: "10"), .init(name: "country", value: country)]
            let want = Self.looseKey(t.title, t.artist)
            var id: Int?
            if let (data, _) = try? await URLSession.shared.data(from: comps.url!),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                id = (json["results"] as? [[String: Any]] ?? []).first {
                    Self.looseKey($0["trackName"] as? String ?? "", $0["artistName"] as? String ?? "") == want
                }?["trackId"] as? Int
            }
            if let id, (try? await playlist.addItem(withProductID: String(id))) != nil { continue }
            catalogTried[tk] = now
            failed += 1
        }
        return failed + max(0, tracks.count - 25)
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
