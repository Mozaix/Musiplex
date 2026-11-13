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
