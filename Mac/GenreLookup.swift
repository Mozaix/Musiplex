import Foundation
import Observation

/// Your songs have no genre tags, so Musiplex can (if you turn it on) look up
/// each *artist's* genre once using Apple's free public music search
/// (itunes.apple.com). Only artist names are sent: never what you play. The
/// answers are saved, so each artist is only ever asked about once.
@MainActor @Observable
final class GenreLookup {
    var enabled = UserDefaults.standard.bool(forKey: "genreLookup") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "genreLookup")
            if enabled { start() } else { task?.cancel(); task = nil; running = false }
        }
    }
    /// Lower-cased primary artist → genre ("" = looked up, nothing found).
    private(set) var genres: [String: String] = [:]
    private(set) var running = false
    private(set) var remaining = 0

    /// Which artists to look up (asked for each time it runs).
    @ObservationIgnored var artists: (() -> [String])?
    /// Called when new genres arrive.
    @ObservationIgnored var onUpdate: (([String: String]) -> Void)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let fileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Musiplex/artist-genres.json")

    init() {
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            genres = saved
        }
    }

    /// "Drake, 21 Savage" / "A & B" / "X feat. Y" → "drake"
    nonisolated static func primary(_ artist: String) -> String {
        let lowered = artist.lowercased()
        let cut = lowered.range(of: #",| & | x | feat\.? | ft\.? | with "#, options: .regularExpression)
        return String(cut.map { lowered[..<$0.lowerBound] } ?? lowered[...]).trimmingCharacters(in: .whitespaces)
    }

    func start() {
        guard enabled, task == nil, let artists else { return }
        let todo = Array(Set(artists().map(Self.primary))).filter { !$0.isEmpty && genres[$0] == nil }.sorted()
        remaining = todo.count
        guard !todo.isEmpty else { return }
        running = true
        task = Task { [weak self] in
            let session = URLSession(configuration: .ephemeral)
            var batch = 0
            for artist in todo {
                guard let self, !Task.isCancelled else { break }
                let genre = await Self.lookUp(artist, session: session)
                // nil = network trouble: try again next time. "" = no match.
                if let genre {
                    self.genres[artist] = genre
                    batch += 1
                    if batch % 10 == 0 { self.save(); self.onUpdate?(self.genres) }
                }
                self.remaining -= 1
                // Apple allows roughly 20 searches a minute.
                try? await Task.sleep(for: .seconds(3.2))
            }
            guard let self else { return }
            self.save()
            self.onUpdate?(self.genres)
            self.running = false
            self.task = nil
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(genres) { try? data.write(to: fileURL, options: .atomic) }
    }

    /// Apple's genre for an artist; "" if there's no match; nil on a network error.
    nonisolated private static func lookUp(_ artist: String, session: URLSession) async -> String? {
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [
            URLQueryItem(name: "term", value: artist),
            URLQueryItem(name: "entity", value: "musicArtist"),
            URLQueryItem(name: "limit", value: "3"),
        ]
        guard let url = comps.url,
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return nil }
        // Prefer an exact name match.
        let exact = results.first { ($0["artistName"] as? String)?.lowercased() == artist }
        return (exact ?? results.first)?["primaryGenreName"] as? String ?? ""
    }
}
