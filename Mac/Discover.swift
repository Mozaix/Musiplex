import AppKit
import AVFoundation
import Observation
import SwiftUI

/// New songs in a genre, found on Apple's free music search (no account, no Spotify Premium):
/// songs by artists you already play in that genre that you don't own yet, mixed with the
/// genre's current chart. Each has a 30-second preview, a link to open it in Spotify, and the
/// whole list exports as a CSV that TuneMyMusic or Soundiiz import into a free Spotify account.
/// Only genre names and artist names are sent (to Apple).
@MainActor @Observable
final class Discover {
    struct Song: Codable, Hashable, Identifiable {
        var title: String
        var artist: String
        var album: String
        var preview: String?
        var link: String?
        var artwork: String?
        var id: String { "\(title)|\(artist)" }
    }

    /// Genre → its list (saved, so it's there next time).
    private(set) var lists: [String: [Song]] = [:]
    private(set) var working: String?
    private(set) var playing: String?
    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var endObserver: Any?
    @ObservationIgnored private let fileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Musiplex/discover.json")

    init() {
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode([String: [Song]].self, from: data) {
            lists = saved
        }
    }

    /// Apple's chart genre IDs for each Musiplex genre family.
    private static let chartGenres: [String: [Int]] = [
        "Hip-Hop/Rap": [18], "R&B/Soul": [15], "Electronic": [7, 17], "Rock": [21],
        "Alternative/Indie": [20], "Pop": [14], "Jazz/Blues": [11, 2], "Classical/Score": [5, 16],
        "Latin": [12], "Country/Folk": [6, 10], "Reggae/Afro": [24],
    ]

    /// Builds (or refreshes) the list for a genre. `artists` = yours in it, most played first;
    /// `have` = song keys of everything in your library (never suggested).
    func find(genre: String, artists: [String], have: Set<String>, count: Int = 40) async {
        guard working == nil else { return }
        working = genre
        defer { working = nil }
        let session = URLSession(configuration: .ephemeral)
        let previous = Set((lists[genre] ?? []).map(\.id))

        // 1. More songs from the artists you play in this genre.
        var fromArtists: [Song] = []
        for artist in artists.prefix(10) {
            var comps = URLComponents(string: "https://itunes.apple.com/search")!
            comps.queryItems = [.init(name: "term", value: artist), .init(name: "entity", value: "song"),
                                .init(name: "attribute", value: "artistTerm"), .init(name: "limit", value: "25")]
            guard let json = await Self.get(comps.url!, session) else { continue }
            let songs = (json["results"] as? [[String: Any]] ?? []).compactMap { r -> Song? in
                guard let title = r["trackName"] as? String, let name = r["artistName"] as? String,
                      GenreLookup.primary(name) == GenreLookup.primary(artist) else { return nil }
                return Song(title: title, artist: name, album: r["collectionName"] as? String ?? "",
                            preview: r["previewUrl"] as? String, link: r["trackViewUrl"] as? String,
                            artwork: r["artworkUrl100"] as? String)
            }
            fromArtists += songs
            try? await Task.sleep(for: .milliseconds(400))   // be gentle with Apple's free search
        }

        // 2. What's popular in the genre right now.
        var fromChart: [Song] = []
        for id in Self.chartGenres[genre] ?? [] {
            guard let json = await Self.get(URL(string: "https://itunes.apple.com/us/rss/topsongs/limit=100/genre=\(id)/json")!, session),
                  let entries = (json["feed"] as? [String: Any])?["entry"] as? [[String: Any]] else { continue }
            for e in entries {
                func label(_ key: String) -> String? { (e[key] as? [String: Any])?["label"] as? String }
                guard let title = label("im:name"), let artist = label("im:artist") else { continue }
                let links = (e["link"] as? [[String: Any]] ?? []).compactMap { ($0["attributes"] as? [String: Any])?["href"] as? String }
                let art = (e["im:image"] as? [[String: Any]])?.last?["label"] as? String
                fromChart.append(Song(title: title, artist: artist, album: ((e["im:collection"] as? [String: Any])?["im:name"] as? [String: Any])?["label"] as? String ?? "",
                                      preview: links.first { $0.hasSuffix(".m4a") }, link: links.first { $0.contains("music.apple.com") },
                                      artwork: art))
            }
        }

        // Mix: two from your artists for every one from the chart; nothing you own,
        // no repeats of the last list, at most two per artist.
        var picked: [Song] = []
        var keys = have
        var perArtist: [String: Int] = [:]
        func take(_ song: Song) {
            let key = songKey(title: Self.clean(song.title), artist: song.artist)
            let who = GenreLookup.primary(song.artist)
            guard picked.count < count, !previous.contains(song.id), perArtist[who, default: 0] < 2,
                  keys.insert(key).inserted, keys.insert(songKey(title: song.title, artist: song.artist)).inserted else { return }
            perArtist[who, default: 0] += 1
            picked.append(song)
        }
        var a = fromArtists.shuffled().makeIterator(), c = fromChart.makeIterator()
        var more = true
        while picked.count < count, more {
            more = false
            for _ in 0..<2 { if let s = a.next() { take(s); more = true } }
            if let s = c.next() { take(s); more = true }
        }
        guard !picked.isEmpty else { return }
        lists[genre] = picked
        save()
    }

    /// "Song (feat. X)" / "Song - Remastered" → "Song", so owned songs are recognised.
    private static func clean(_ title: String) -> String {
        let cut = title.range(of: #"\s*(\(|\[| - ).*$"#, options: .regularExpression)
        return cut.map { String(title[..<$0.lowerBound]) } ?? title
    }

    private static func get(_ url: URL, _ session: URLSession) async -> [String: Any]? {
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func save() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(lists) { try? data.write(to: fileURL, options: .atomic) }
    }

    // MARK: Preview

    func togglePreview(_ song: Song) {
        if playing == song.id { stopPreview(); return }
        guard let s = song.preview, let url = URL(string: s) else { return }
        stopPreview()
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.volume = 0.8
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopPreview() }
        }
        p.play()
        player = p
        playing = song.id
    }

    func stopPreview() {
        player?.pause()
        player = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        playing = nil
    }

    // MARK: To Spotify (free account)

    static func spotifySearch(_ song: Song) -> URL? {
        let q = "\(song.title) \(song.artist)".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(.init(charactersIn: "/?&#"))) ?? ""
        return URL(string: "https://open.spotify.com/search/\(q)")
    }

    /// Saves "Musiplex · Genre.csv" (Track name, Artist name, Album) to Downloads and
    /// shows it in Finder; TuneMyMusic and Soundiiz turn it into a Spotify playlist.
    @discardableResult
    func exportCSV(_ genre: String) -> URL? {
        guard let songs = lists[genre], !songs.isEmpty else { return nil }
        func field(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let rows = ["Track name,Artist name,Album"] + songs.map { [field($0.title), field($0.artist), field($0.album)].joined(separator: ",") }
        let safe = genre.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Musiplex · \(safe).csv")
        guard (try? rows.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return url
    }

    /// "Artist - Title" lines, for pasting into TuneMyMusic's "Free text" source.
    func copyText(_ genre: String) {
        let text = (lists[genre] ?? []).map { "\($0.artist) - \($0.title)" }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The Discover list for one genre.
struct DiscoverSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let genre: String
    @State private var copied = false

    var body: some View {
        let discover = model.discover
        let songs = discover.lists[genre] ?? []
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Discover · \(genre)").font(.title2.bold())
                    Text("New songs like yours: more from artists you play, plus what's popular in \(genre). None of them are in your library.")
                        .font(.caption).foregroundStyle(Theme.dim)
                }
                Spacer()
                Button("Done") { discover.stopPreview(); dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 8) {
                Button { model.discoverGenre(genre) } label: {
                    Label(songs.isEmpty ? "Find Songs" : "Find Different Songs", systemImage: "sparkle.magnifyingglass")
                }
                .disabled(discover.working != nil)
                if discover.working == genre { ProgressView().controlSize(.small) }
                Spacer()
                if !songs.isEmpty {
                    Button { discover.exportCSV(genre) } label: { Label("Save CSV", systemImage: "square.and.arrow.down") }
                        .help("Saves the list to Downloads for TuneMyMusic or Soundiiz")
                    Button {
                        discover.copyText(genre)
                        copied = true
                    } label: { Label(copied ? "Copied" : "Copy List", systemImage: copied ? "checkmark" : "doc.on.doc") }
                    Button { NSWorkspace.shared.open(URL(string: "https://www.tunemymusic.com/transfer")!) } label: {
                        Label("Open TuneMyMusic", systemImage: "arrow.up.right.square")
                    }
                }
            }
            if !songs.isEmpty {
                Text("To make it a Spotify playlist with a free account: press **Copy List**, open TuneMyMusic, choose **Free text** as the source, paste, pick Spotify as the destination. (Or **Save CSV** and upload the file there or on Soundiiz.)")
                    .font(.caption).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
            }
            if songs.isEmpty {
                Spacer()
                Text(discover.working == genre ? "Looking…" : "Press Find Songs. Only genre and artist names are sent, to Apple's free music search.")
                    .foregroundStyle(Theme.dim).frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(songs) { song in DiscoverRow(song: song) }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 640, height: 560)
        .background(Theme.panel)
        .onDisappear { discover.stopPreview() }
    }
}

private struct DiscoverRow: View {
    @Environment(AppModel.self) private var model
    let song: Discover.Song

    var body: some View {
        let discover = model.discover
        let isPlaying = discover.playing == song.id
        HStack(spacing: 10) {
            AsyncImage(url: song.artwork.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: { Theme.raised }
            .frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 5))
            Button {
                if !isPlaying, model.session.state.isPlaying { model.send("pause") }
                discover.togglePreview(song)
            } label: {
                Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill").font(.system(size: 20))
            }
            .buttonStyle(.plain).foregroundStyle(song.preview == nil ? Theme.dim : Theme.accent)
            .disabled(song.preview == nil)
            .help("Play a 30-second preview")
            VStack(alignment: .leading, spacing: 1) {
                Text(song.title).lineLimit(1)
                Text(song.artist).font(.caption).foregroundStyle(Theme.dim).lineLimit(1)
            }
            Spacer()
            Text(song.album).font(.caption).foregroundStyle(Theme.dim).lineLimit(1).frame(maxWidth: 180, alignment: .trailing)
            Button { if let url = Discover.spotifySearch(song) { NSWorkspace.shared.open(url) } } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.plain).foregroundStyle(Theme.dim)
            .help("Find it on Spotify")
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(isPlaying ? Theme.raised : .clear, in: RoundedRectangle(cornerRadius: 6))
    }
}
