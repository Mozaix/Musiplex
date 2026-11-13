import Foundation
import Observation

/// Quietly fetches the next few songs in the queue while streaming from the
/// Mac, so the next song starts instantly (and crossfades cleanly) even on a
/// weak connection. Lives in Caches — iOS may clear it, and it never counts
/// as a download. Keeps only a handful of files.
@MainActor @Observable
final class UpcomingCache {
    var enabled = UserDefaults.standard.object(forKey: "cacheUpcoming") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "cacheUpcoming")
            if !enabled { clear() }
        }
    }
    /// How many upcoming songs to keep ready.
    var count = UserDefaults.standard.object(forKey: "cacheUpcomingCount") as? Int ?? 3 {
        didSet { UserDefaults.standard.set(count, forKey: "cacheUpcomingCount") }
    }

    @ObservationIgnored private var files: [String: URL] = [:]
    @ObservationIgnored private var inflight = Set<String>()
    @ObservationIgnored private let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("upcoming", isDirectory: true)

    init() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for url in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            files[url.deletingPathExtension().lastPathComponent] = url
        }
    }

    func url(for id: String) -> URL? {
        guard let url = files[id] else { return nil }
        if FileManager.default.fileExists(atPath: url.path) { return url }
        files[id] = nil
        return nil
    }

    /// Makes sure these songs are cached (in order) and drops anything else.
    func keep(_ tracks: [Track], current: String?, source: (Track) -> URL?) {
        guard enabled else { return }
        let wanted = Array(tracks.prefix(count))
        let keepIDs = Set(wanted.map(\.id) + [current].compactMap { $0 })
        for (id, url) in files where !keepIDs.contains(id) && !inflight.contains(id) {
            try? FileManager.default.removeItem(at: url)
            files[id] = nil
        }
        for track in wanted where files[track.id] == nil && !inflight.contains(track.id) {
            guard let remote = source(track) else { continue }
            inflight.insert(track.id)
            let target = dir.appendingPathComponent("\(track.id).\(track.ext)")
            let id = track.id
            let task = URLSession.shared.downloadTask(with: remote) { [weak self] location, response, _ in
                var ok = false
                if let location, (response as? HTTPURLResponse)?.statusCode == 200 {
                    try? FileManager.default.removeItem(at: target)
                    ok = (try? FileManager.default.moveItem(at: location, to: target)) != nil
                }
                Task { @MainActor in
                    self?.inflight.remove(id)
                    if ok { self?.files[id] = target }
                }
            }
            task.priority = URLSessionTask.lowPriority
            task.resume()
        }
    }

    func clear() {
        for url in files.values { try? FileManager.default.removeItem(at: url) }
        files = [:]
    }
}
