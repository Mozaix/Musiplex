import Foundation

/// A tiny on-device taste model. No machine-learning framework and no network:
/// just counts, kept small on purpose.
///
/// Per song it keeps: plays, skips, when it was last played, and which hours
/// of the day and days of the week you play it. It also remembers which songs
/// you tend to play *after* which (top few per song). That's a few hundred
/// bytes per song you've actually played; nothing for songs you haven't.
///
/// - **Surprise** picks the next song on the fly from what's playing now:
///   songs you often play next, the same genre or artist, things you like at
///   this hour, a little discovery, and never something you just heard.
/// - **Guess** builds a playlist for right now: the songs and genres you play
///   at this time of day on this kind of day.
final class Recommender {
    struct Stat: Codable {
        var p = 0                               // plays (heard most of it)
        var k = 0                               // skips
        var l = 0.0                             // last played (seconds since 1970)
        var h = [UInt16](repeating: 0, count: 24) // plays per hour of day
        var d = [UInt16](repeating: 0, count: 7)  // plays per weekday (0 = Sunday)
    }

    private struct Store: Codable {
        var stats: [String: Stat] = [:]
        /// song → songs played right after it → how often.
        var next: [String: [String: UInt16]] = [:]
    }

    private var store = Store()
    private let url: URL
    private var dirty = false
    private var saveTask: DispatchWorkItem?
    /// Cached genre per song (with gaps filled from the artist), rebuilt when the library changes.
    private var genreCache: (key: Int, map: [String: String])?

    /// Keep at most this many "played next" links per song.
    private let nextLimit = 10

    init(file: String = "taste.json") {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if os(macOS)
        url = dir.appendingPathComponent("Musiplex").appendingPathComponent(file)
        #else
        url = dir.appendingPathComponent(file)
        #endif
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Store.self, from: data) {
            store = saved
        }
    }

    var hasHistory: Bool { !store.stats.isEmpty }
    var playedCount: Int { store.stats.count }

    // MARK: Learning

    /// Call when a song stops playing. `heard` = seconds listened, `length` = song length.
    func record(_ id: String, heard: Double, length: Double, after previous: String?, at date: Date = Date()) {
        guard heard >= 1 else { return }
        let fraction = length > 0 ? heard / length : 1
        let skipped = heard < 30 && fraction < 0.4
        var s = store.stats[id] ?? Stat()
        if skipped {
            s.k += 1
        } else {
            s.p += 1
            s.l = date.timeIntervalSince1970
            let cal = Calendar.current
            let hour = cal.component(.hour, from: date), day = cal.component(.weekday, from: date) - 1
            s.h[hour] = s.h[hour] &+ 1
            s.d[day] = s.d[day] &+ 1
            if let previous, previous != id {
                var links = store.next[previous] ?? [:]
                links[id, default: 0] &+= 1
                if links.count > nextLimit, let weakest = links.min(by: { $0.value < $1.value })?.key { links[weakest] = nil }
                store.next[previous] = links
            }
        }
        store.stats[id] = s
        scheduleSave()
    }

    /// Adds counts learned elsewhere (another device's history).
    func merge(_ data: Data) {
        guard let other = try? JSONDecoder().decode(Store.self, from: data) else { return }
        for (id, o) in other.stats {
            var s = store.stats[id] ?? Stat()
            s.p = max(s.p, o.p); s.k = max(s.k, o.k); s.l = max(s.l, o.l)
            for i in 0..<24 { s.h[i] = max(s.h[i], o.h[i]) }
            for i in 0..<7 { s.d[i] = max(s.d[i], o.d[i]) }
            store.stats[id] = s
        }
        for (id, links) in other.next {
            var mine = store.next[id] ?? [:]
            for (to, n) in links { mine[to] = max(mine[to] ?? 0, n) }
            while mine.count > nextLimit, let weakest = mine.min(by: { $0.value < $1.value })?.key { mine[weakest] = nil }
            store.next[id] = mine
        }
        scheduleSave()
    }

    /// The whole history, for handing to another device.
    func export() -> Data { (try? JSONEncoder().encode(store)) ?? Data() }

    /// One pending save at a time (a burst of changes is written once).
    private func scheduleSave() {
        guard saveTask == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.saveTask = nil
            self?.saveNow()
        }
        saveTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    func saveNow() {
        if let data = try? JSONEncoder().encode(store) { try? data.write(to: url, options: .atomic) }
    }

    // MARK: Genres

    /// Broad family for a genre tag, so "Trap", "Hip-Hop/Rap" and "Rap" count as one.
    static func family(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let g = raw.lowercased()
        let groups: [(String, [String])] = [
            ("Hip-Hop/Rap", ["hip", "rap", "trap", "drill", "grime"]),
            ("R&B/Soul", ["r&b", "rnb", "soul", "funk", "neo"]),
            ("Electronic", ["electr", "house", "techno", "edm", "dance", "dubstep", "drum", "trance", "phonk", "synth", "ambient"]),
            ("Rock", ["rock", "grunge", "punk", "metal", "emo", "shoegaze"]),
            ("Alternative/Indie", ["altern", "indie", "psychedel", "lo-fi", "lofi", "bedroom"]),
            ("Pop", ["pop", "k-pop", "j-pop"]),
            ("Jazz/Blues", ["jazz", "blues", "swing"]),
            ("Classical/Score", ["classic", "orchestr", "piano", "soundtrack", "score", "instrumental", "game"]),
            ("Latin", ["latin", "reggaeton", "salsa", "bachata", "urbano"]),
            ("Country/Folk", ["country", "folk", "acoustic", "singer"]),
            ("Reggae/Afro", ["reggae", "afro", "dancehall", "amapiano"]),
            ("Arabic", ["arab", "khaleeji", "shaabi"]),
        ]
        for (name, words) in groups where words.contains(where: { g.contains($0) }) { return name }
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }

    /// Genre family for every song; songs without a tag borrow their artist's most common genre.
    func genres(_ tracks: [Track]) -> [String: String] {
        // Rebuilt when the song count or the number of tagged songs changes.
        let key = tracks.count &* 31 &+ tracks.reduce(0) { $0 &+ ($1.genre == nil ? 0 : 1) }
        if let cache = genreCache, cache.key == key { return cache.map }
        var byArtist: [String: [String: Int]] = [:]
        var map: [String: String] = [:]
        for t in tracks {
            guard let f = Self.family(t.genre) else { continue }
            map[t.id] = f
            byArtist[t.artist.lowercased(), default: [:]][f, default: 0] += 1
        }
        for t in tracks where map[t.id] == nil {
            if let best = byArtist[t.artist.lowercased()]?.max(by: { $0.value < $1.value })?.key { map[t.id] = best }
        }
        genreCache = (key, map)
        return map
    }

    /// Your genres, strongest first: what you play (weighted) plus what you own.
    func taste(_ tracks: [Track]) -> [(genre: String, share: Double)] {
        let map = genres(tracks)
        var weight: [String: Double] = [:]
        for t in tracks {
            guard let g = map[t.id] else { continue }
            let s = store.stats[t.id]
            weight[g, default: 0] += 1 + Double(s?.p ?? 0) * 3 - Double(s?.k ?? 0)
        }
        let total = max(weight.values.reduce(0) { $0 + max($1, 0) }, 1)
        return weight.map { ($0.key, max($0.value, 0) / total) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
    }

    // MARK: Picking

    /// How much you like a song in general (plays vs skips, softened).
    private func liking(_ id: String) -> Double {
        guard let s = store.stats[id] else { return 0 }
        let plays = Double(s.p), skips = Double(s.k)
        return log1p(plays) - 1.5 * skips / (plays + skips + 1)
    }

    /// Songs you haven't played yet that fit the genres you play most.
    func discover(tracks: [Track], count: Int = 12) -> [String] {
        let map = genres(tracks)
        let share = Dictionary(taste(tracks).map { ($0.genre, $0.share) }, uniquingKeysWith: { a, _ in a })
        var rng = SeededRandom(seed: UInt64(Date().timeIntervalSince1970 / 86400))
        return tracks.filter { store.stats[$0.id] == nil }
            .map { ($0.id, (map[$0.id].flatMap { share[$0] } ?? 0) * 4 + Double.random(in: 0...1, using: &rng)) }
            .sorted { $0.1 > $1.1 }
            .prefix(count).map(\.0)
    }

    /// How much this song belongs to this hour (±1 h) and kind of day.
    private func timeFit(_ s: Stat?, hour: Int, weekend: Bool) -> Double {
        guard let s, s.p > 0 else { return 0 }
        let h = Double(s.h[hour]) + 0.5 * Double(s.h[(hour + 23) % 24]) + 0.5 * Double(s.h[(hour + 1) % 24])
        let dayPlays = weekend ? Double(s.d[0]) + Double(s.d[6]) : (1...5).reduce(0.0) { $0 + Double(s.d[$1]) }
        let dayShare = dayPlays / Double(max(s.p, 1))
        return h / Double(s.p) * 2 + (weekend ? dayShare * 3.5 : dayShare * 1.4)
    }

    /// Picks the next Surprise song. `recent` = songs heard lately (never repeated).
    func surpriseNext(after current: String?, recent: [String], tracks: [Track], date: Date = Date()) -> String? {
        guard !tracks.isEmpty else { return nil }
        let map = genres(tracks)
        let avoid = Set(recent.suffix(60) + [current].compactMap { $0 })
        let nowTrack = current.flatMap { id in tracks.first { $0.id == id } }
        let nowGenre = current.flatMap { map[$0] }
        let lastArtists = recent.suffix(2).compactMap { id in tracks.first { $0.id == id }?.artist }
        let links = current.flatMap { store.next[$0] } ?? [:]
        let linkMax = Double(links.values.max() ?? 1)
        let tasteShare = Dictionary(taste(tracks).map { ($0.genre, $0.share) }, uniquingKeysWith: { a, _ in a })
        let cal = Calendar.current
        let hour = cal.component(.hour, from: date)
        let weekday = cal.component(.weekday, from: date)
        let weekend = weekday == 1 || weekday == 7

        var scored: [(id: String, score: Double)] = []
        scored.reserveCapacity(tracks.count)
        for t in tracks where !avoid.contains(t.id) {
            let s = store.stats[t.id]
            var score = liking(t.id)
            if let n = links[t.id] { score += 3 * Double(n) / linkMax }          // you often play this next
            let g = map[t.id]
            if let g, g == nowGenre { score += 1.2 } else if let g { score += (tasteShare[g] ?? 0) * 2 }
            if let nowTrack, t.artist == nowTrack.artist { score += 0.4 }
            if lastArtists.count == 2, lastArtists.allSatisfy({ $0 == t.artist }) { score -= 2 } // no 3 in a row
            score += 0.6 * timeFit(s, hour: hour, weekend: weekend)
            if s == nil { score += 0.35 }                                         // a little discovery
            if let s, s.l > 0, date.timeIntervalSince1970 - s.l < 3 * 3600 { score -= 1.5 } // heard very recently
            scored.append((t.id, score))
        }
        return Self.sample(scored, top: 25)
    }

    /// A playlist for right now (time of day + weekday/weekend). Stable within the hour.
    func guess(tracks: [Track], date: Date = Date(), count: Int = 30) -> [String] {
        guard !tracks.isEmpty else { return [] }
        let map = genres(tracks)
        let cal = Calendar.current
        let hour = cal.component(.hour, from: date)
        let weekday = cal.component(.weekday, from: date)
        let weekend = weekday == 1 || weekday == 7

        // What genres you lean on at this hour, learned from everything you've played.
        var genreNow: [String: Double] = [:]
        for (id, s) in store.stats {
            guard let g = map[id] else { continue }
            genreNow[g, default: 0] += timeFit(s, hour: hour, weekend: weekend) * Double(s.p)
        }
        let genreMax = max(genreNow.values.max() ?? 1, 1)
        let tasteShare = Dictionary(taste(tracks).map { ($0.genre, $0.share) }, uniquingKeysWith: { a, _ in a })

        // Seeded by the hour, so it doesn't reshuffle every time you look.
        var rng = SeededRandom(seed: UInt64(date.timeIntervalSince1970 / 3600))
        var scored: [(id: String, score: Double)] = tracks.map { t in
            let s = store.stats[t.id]
            var score = liking(t.id) + 1.5 * timeFit(s, hour: hour, weekend: weekend)
            if let g = map[t.id] { score += 2 * (genreNow[g] ?? 0) / genreMax + (tasteShare[g] ?? 0) }
            if let s, date.timeIntervalSince1970 - s.l < 2 * 3600 { score -= 1 }
            score += Double.random(in: 0...0.6, using: &rng)
            return (t.id, score)
        }
        scored.sort { $0.score > $1.score }

        // At most two songs per artist, so it isn't one album on repeat.
        var perArtist: [String: Int] = [:]
        let artist = Dictionary(tracks.map { ($0.id, $0.artist) }, uniquingKeysWith: { a, _ in a })
        var out: [String] = []
        for item in scored where out.count < count {
            let a = artist[item.id] ?? ""
            if perArtist[a, default: 0] >= 2 { continue }
            perArtist[a, default: 0] += 1
            out.append(item.id)
        }
        return out
    }

    /// "Tuesday evening", "Weekend morning", …
    static func moment(_ date: Date = Date()) -> String {
        let cal = Calendar.current
        let hour = cal.component(.hour, from: date)
        let part = switch hour {
        case 5..<12: "morning"
        case 12..<17: "afternoon"
        case 17..<22: "evening"
        default: "night"
        }
        let day = date.formatted(.dateTime.weekday(.wide))
        return "\(day) \(part)"
    }

    /// Weighted random pick among the best few (softmax), so it isn't predictable.
    private static func sample(_ scored: [(id: String, score: Double)], top: Int) -> String? {
        let best = scored.sorted { $0.score > $1.score }.prefix(top)
        guard let maxScore = best.first?.score else { return nil }
        let weights = best.map { exp(($0.score - maxScore) * 1.6) }
        var r = Double.random(in: 0..<weights.reduce(0, +))
        for (item, w) in zip(best, weights) {
            r -= w
            if r <= 0 { return item.id }
        }
        return best.first?.id
    }
}

/// Small deterministic random generator (SplitMix64).
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Watches playback and tells the recommender what was played, skipped, and in
/// which order. It times listening by the clock (no polling): it only needs to
/// hear about play/pause and song changes.
final class ListeningRecorder {
    private let recommender: Recommender
    private var current: String?
    private var heard = 0.0
    private var since: Date?
    private var previousPlayed: String?
    /// Songs heard lately, newest last (Surprise avoids repeating them).
    private(set) var recent: [String] = []

    init(_ recommender: Recommender) { self.recommender = recommender }

    func observe(id: String?, playing: Bool, length: (String) -> Double) {
        let now = Date()
        if let since { heard += now.timeIntervalSince(since) }
        since = playing && id != nil ? now : nil
        guard id != current else { return }
        if let old = current {
            let len = length(old)
            recommender.record(old, heard: heard, length: len, after: previousPlayed)
            let skipped = heard < 30 && (len <= 0 || heard / len < 0.4)
            if !skipped { previousPlayed = old }
            recent.append(old)
            if recent.count > 80 { recent.removeFirst(recent.count - 80) }
        }
        current = id
        heard = 0
    }
}
