import Foundation

struct Track: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var ext: String
    var size: Int64
    var addedAt: Double
    /// From the file's tags or the Music app (nil when there's none).
    var genre: String? = nil
}

/// A named, ordered list of tracks: a playlist, or an album in the catalog.
struct Playlist: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var subtitle: String?
    var trackIDs: [String]
}

/// Everything the Mac shares with devices in one payload.
struct Catalog: Codable {
    var tracks: [Track]
    var albums: [Playlist]
    var playlists: [Playlist]
    /// Playlist change history, newest first.
    var history: [PlaylistVersion]? = nil
}

/// One change to one playlist inside a version.
struct PlaylistChange: Codable, Hashable {
    enum Kind: String, Codable { case created, renamed, deleted, added, removed }
    var playlist: String
    var kind: Kind
    /// "Title — Artist" for added/removed songs.
    var songs: [String] = []
    /// Old name for a rename.
    var detail: String? = nil
    /// Which playlist and which song IDs, so the change can be reverted.
    var playlistID: String? = nil
    var ids: [String]? = nil
}

/// A numbered snapshot of playlist edits (1.1, 1.2, …): when, from which
/// device, and exactly which songs changed in which playlist.
struct PlaylistVersion: Codable, Identifiable, Hashable {
    var number: Int
    var date: Date
    /// Where the edit came from: "This Mac", "Sam's iPhone", "Apple Music on Sam's iPhone".
    var source: String
    var changes: [PlaylistChange]
    /// Set when this version undid another one.
    var reverts: Int? = nil

    var id: Int { number }
    var label: String { "1.\(number)" }

    var summary: String {
        let added = changes.filter { $0.kind == .added }.reduce(0) { $0 + $1.songs.count }
        let removed = changes.filter { $0.kind == .removed }.reduce(0) { $0 + $1.songs.count }
        var parts: [String] = []
        if added > 0 { parts.append("+\(added) song\(added == 1 ? "" : "s")") }
        if removed > 0 { parts.append("−\(removed) song\(removed == 1 ? "" : "s")") }
        for c in changes where c.kind == .created { parts.append("new “\(c.playlist)”") }
        for c in changes where c.kind == .renamed { parts.append("renamed “\(c.playlist)”") }
        for c in changes where c.kind == .deleted { parts.append("deleted “\(c.playlist)”") }
        let lists = Set(changes.map(\.playlist))
        if (added > 0 || removed > 0), lists.count == 1, let name = lists.first { parts.append("in “\(name)”") }
        if let reverts { parts.insert("Undid 1.\(reverts)", at: 0) }
        return parts.isEmpty ? "No changes" : parts.joined(separator: " · ")
    }
}

struct DeviceInfo: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    /// "mac", "iphone" or "ipad"
    var kind: String

    var symbol: String {
        switch kind {
        case "mac": "laptopcomputer"
        case "ipad": "ipad"
        case "android": "smartphone"
        default: "iphone"
        }
    }
}

enum RepeatMode: String, Codable { case off, all, one }

/// The single shared playback session. The Mac owns it; the phone follows it.
struct SessionState: Codable, Equatable {
    var queue: [String] = []
    var index = 0
    var isPlaying = false
    var position: Double = 0
    /// ID of the audible device: "mac" or a phone/iPad's device ID.
    /// Every other device mirrors, muted.
    var activeDevice = "mac"
    var volume: Double = 0.8
    var shuffle = false
    var repeatMode = RepeatMode.off
    /// Crossfade length in seconds (0 = off). Applies on every device.
    var crossfade: Double = 0
    /// How long the most recent song change fades (crossfade on auto-advance, 0 for skips).
    var fade: Double = 0
    /// "surprise" while Surprise is picking songs as it goes.
    var radio: String? = nil

    var currentID: String? { queue.indices.contains(index) ? queue[index] : nil }
}

/// Actions: play, jump, toggle, pause, resume, next, prev, seek, volume,
/// device, shuffle, repeat, playNext, enqueue, auto
struct Command: Codable {
    var action: String
    var ids: [String]? = nil
    var index: Int? = nil
    var value: Double? = nil
    var text: String? = nil
}

/// Mac → device: welcome, denied, state, tick, devices, library, download, noArt
/// Device → Mac: hello, command, fetch (nearby only: text = file | art | catalog)
struct Message: Codable {
    var type: String
    var token: String? = nil
    var pin: String? = nil
    var name: String? = nil
    var state: SessionState? = nil
    var command: Command? = nil
    var position: Double? = nil
    var isPlaying: Bool? = nil
    var deviceID: String? = nil
    var kind: String? = nil
    var devices: [DeviceInfo]? = nil
    var ids: [String]? = nil
    var text: String? = nil
    /// Other addresses the Mac can be reached at (Tailscale IP / MagicDNS name).
    var hosts: [String]? = nil
    /// Songs to take out of a playlist (playlist edits).
    var removeIDs: [String]? = nil
    /// Command sequence number, so a command sent over two links runs once.
    var seq: Int? = nil
    /// Who made a playlist edit, when it isn't the device itself ("Apple Music on …").
    var source: String? = nil
}

enum Net {
    static let service = "_musiplex._tcp"
    /// MultipeerConnectivity service (Bluetooth + peer-to-peer Wi‑Fi).
    static let nearbyService = "mplex-near"
    /// Hidden test switch: `debugPortOffset` runs a second copy on other ports.
    private static let offset = UserDefaults.standard.integer(forKey: "debugPortOffset")
    static let httpPort = 7860 + offset
    static let wsPort = 7861 + offset
}

func timeString(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let s = Int(seconds)
    return s >= 3600
        ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
        : String(format: "%d:%02d", s / 60, s % 60)
}

/// Songs that are the same recording (same title and artist, length within
/// 3 s), mapped to the best-quality copy that should be kept.
/// Loose "same song" key: title + artist with case, accents, spaces and punctuation ignored.
func songKey(title: String, artist: String) -> String {
    func norm(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }
    return "\(norm(title))|\(norm(artist))"
}

func findDuplicates(in tracks: [Track]) -> [String: String] {
    func norm(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }
    var result: [String: String] = [:]
    let groups = Dictionary(grouping: tracks) { "\(norm($0.title))|\(norm($0.artist))" }
    for (_, group) in groups where group.count > 1 {
        // Best first: higher bitrate, then the one added earliest.
        let ranked = group.sorted {
            let a = Double($0.size) / max($0.duration, 1), b = Double($1.size) / max($1.duration, 1)
            return a != b ? a > b : $0.addedAt < $1.addedAt
        }
        var kept: [Track] = []
        for t in ranked {
            if let keeper = kept.first(where: { abs($0.duration - t.duration) <= 3 }) {
                result[t.id] = keeper.id
            } else {
                kept.append(t)
            }
        }
    }
    return result
}
