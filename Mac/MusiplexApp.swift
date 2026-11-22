import AppKit
import Observation
import SwiftUI

enum Route: Hashable {
    case home, songs, albums, artists
    case album(String)
    case artist(String)
    case playlist(String)
    case settings
}

@MainActor @Observable
final class AppModel {
    let library = LibraryStore()
    let session = SessionController(device: "mac")
    let server: Server
    var route: Route = .home
    var search = ""
    var showQueue = false
    /// The "name this playlist" prompt (new or rename).
    var playlistPrompt: PlaylistPrompt?
    /// Short status message shown at the bottom of the window.
    var toast: String?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    let shelf = Shelf()
    let clipboard = ClipboardHistory()
    let notes = NotesStore()
    let money = Money()
    let remote = RemoteAccess()
    let battery = Battery()
    @ObservationIgnored private(set) var notch: NotchController!
    /// The notch overlay at the top of the screen (on by default).
    var notchEnabled = UserDefaults.standard.object(forKey: "notchEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(notchEnabled, forKey: "notchEnabled")
            notchEnabled ? notch.start() : notch.stop()
        }
    }
    @ObservationIgnored private var nowPlaying: NowPlayingBridge?

    /// Learns from what you play; powers Surprise and Guess. Runs on this Mac only.
    let recommender = Recommender()
    let genreLookup = GenreLookup()
    /// The built-in browser (only exists while its window is open).
    let browser = Browser()
    /// A Linux (or other) Musiplex server whose Floaters are copied here.
    let linked = LinkedServer()
    /// Workload's school tasks (from the linked Linux server), for the notch calendar.
    @ObservationIgnored lazy var workload = WorkloadTasks(linked: linked)
    let spotify = SpotifyLink()
    let discover = Discover()
    /// The Mac's sound outputs (speakers, AirPods, Bluetooth speakers, AirPlay).
    let outputs = AudioOutputs()
    @ObservationIgnored private(set) var recorder: ListeningRecorder!
    @ObservationIgnored private var guessHour = -1
    @ObservationIgnored private var guessTimer: Timer?

    /// Re-send your playlists to the Music app whenever they change.
    var autoPushToAppleMusic = UserDefaults.standard.bool(forKey: "autoPushAppleMusic") {
        didSet { UserDefaults.standard.set(autoPushToAppleMusic, forKey: "autoPushAppleMusic") }
    }
    @ObservationIgnored private var pushQueue = Set<String>()
    @ObservationIgnored private var pushTask: Task<Void, Never>?

    init() {
        server = Server(library: library, session: session)
        let library = library, session = session, server = server

        session.state.volume = UserDefaults.standard.object(forKey: "volume") as? Double ?? 0.8
        session.resolveURL = { library.url(for: $0) }
        session.durationOf = { library.track($0)?.duration ?? 0 }
        session.state.crossfade = UserDefaults.standard.object(forKey: "crossfade") as? Double ?? 0
        let artDir = library.artDir
        ArtCache.shared.loader = { id in NSImage(contentsOf: artDir.appendingPathComponent("\(id).jpg")) }

        let bridge = NowPlayingBridge { session.perform($0) }
        nowPlaying = bridge
        session.onChange = { server.broadcast($0) }
        recorder = ListeningRecorder(recommender)
        session.onApplied = { [weak self] in
            self?.notch?.refresh()
            self?.listened()
            self?.playlistPlayed()
            self?.linked.playbackChanged("\(session.state.currentID ?? "")|\(session.state.isPlaying)")
            bridge.update(track: library.track(session.state.currentID),
                          position: session.livePosition, playing: session.state.isPlaying)
            UserDefaults.standard.set(session.state.volume, forKey: "volume")
            UserDefaults.standard.set(session.state.crossfade, forKey: "crossfade")
        }
        library.onChange = { server.libraryChanged() }
        server.onExport = { [weak self] id in
            guard let self, let list = self.library.playlists.first(where: { $0.id == id }) else { return }
            self.sendToAppleMusic(list)
        }
        server.start()
        remote.start()
        library.setUpSongsFolders()
        if linked.isLinked { linked.start() }
        linked.nowPlaying = { [weak self] in
            guard let self, let t = self.library.track(self.session.state.currentID) else { return nil }
            return ["title": t.title, "artist": t.artist, "album": t.album, "duration": t.duration,
                    "position": self.session.livePosition, "isPlaying": self.session.state.isPlaying]
        }
        linked.chainToken = { [server] in server.chainToken }
        linked.onCommand = { [weak self] c in
            guard let self, let action = c["action"] as? String else { return }
            switch action {
            case "toggle", "next", "prev": self.session.perform(Command(action: action))
            case "surprise": self.startSurprise()
            case "play":
                let key = songKey(title: c["title"] as? String ?? "", artist: c["artist"] as? String ?? "")
                if let t = self.library.tracks.first(where: { songKey(title: $0.title, artist: $0.artist) == key }) {
                    self.session.perform(Command(action: "play", ids: [t.id], index: 0))
                }
            default: break
            }
        }
        server.onSurprise = { [weak self] in self?.startSurprise() }
        server.onTaste = { [weak self] data in self?.recommender.merge(data) }
        server.tasteData = { [weak self] in self?.recommender.export() ?? Data() }
        library.artistGenres = genreLookup.genres
        genreLookup.artists = { [library] in library.tracks.map(\.artist) }
        genreLookup.onUpdate = { [weak self] genres in
            self?.library.artistGenres = genres
            self?.refreshGuess(force: true)
        }
        genreLookup.start()
        refreshGuess(force: true)
        // Re-guess at the top of each hour (one cheap timer, ±1 min tolerance).
        guessTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshGuess() }
        }
        guessTimer?.tolerance = 60
        library.onPlaylistsEdited = { [weak self] ids in self?.queueAutoPush(ids) }
        notch = NotchController(model: self)
        if let report = UserDefaults.standard.string(forKey: "browserTest") {
            // Hidden test switch: open the browser off-screen, load a page and a
            // download, write what happened to `report`, then quit.
            DispatchQueue.main.async { [weak self] in self?.browser.selfTest(report: report, model: self!) }
        } else if let folder = UserDefaults.standard.string(forKey: "notchSnapshot") {
            DispatchQueue.main.async { [weak self] in self?.notch.snapshot(to: folder) }
        } else if notchEnabled {
            DispatchQueue.main.async { [weak self] in self?.notch.start() }
        }
    }

    var currentTrack: Track? { library.track(session.state.currentID) }

    var searchResults: [Track] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return library.tracks.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.artist.localizedCaseInsensitiveContains(q)
                || $0.album.localizedCaseInsensitiveContains(q)
        }
    }

    func play(_ tracks: [Track], at index: Int = 0) {
        session.perform(Command(action: "play", ids: tracks.map(\.id), index: index))
    }

    func send(_ action: String, value: Double? = nil, text: String? = nil) {
        session.perform(Command(action: action, value: value, text: text))
    }

    @ObservationIgnored private var lastQueue: [String] = []

    /// A playlist you start playing (here or from a phone) moves to the top.
    private func playlistPlayed() {
        let queue = session.state.queue
        guard queue != lastQueue else { return }
        lastQueue = queue
        guard queue.count > 1 else { return }
        let set = Set(queue)
        if let list = library.playlists.first(where: { $0.tracks.count == set.count && Set($0.tracks.map(\.id)) == set }),
           library.playlists.first?.id != list.id {
            library.movePlaylist(list.id, before: library.playlists.first?.id)
        }
    }

    // MARK: Genre playlists

    /// Your songs in a genre (as grouped in Your Taste).
    func tracks(inGenre genre: String) -> [Track] {
        let map = recommender.genres(library.tracks)
        return library.tracks.filter { map[$0.id] == genre }
    }

    /// A Musiplex playlist of your songs in this genre (topped up if it already exists).
    func makeGenrePlaylist(_ genre: String) {
        let ids = tracks(inGenre: genre).map(\.id)
        guard !ids.isEmpty else { return }
        if let existing = library.playlists.first(where: { $0.editable && $0.name == genre }) {
            library.add(ids, toPlaylist: existing.id)
        } else {
            library.createPlaylist(named: genre, with: ids)
        }
    }

    /// New songs in this genre on Spotify (not ones you have), in their own Spotify playlist.
    func makeSpotifyPlaylist(_ genre: String) {
        let mine = tracks(inGenre: genre)
        // Search with the genres your songs actually carry first ("Indie Pop", "Alternative"…).
        var counts: [String: Int] = [:]
        for t in mine { if let g = t.genre { counts[g, default: 0] += 1 } }
        var terms = counts.sorted { $0.value > $1.value }.prefix(3).flatMap { Self.spotifyTerms($0.key) }
        terms += Self.spotifyTerms(genre)
        terms = terms.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        let have = Set(library.tracks.map { songKey(title: $0.title, artist: $0.artist) })
        Task { await spotify.makePlaylist(genre: genre, searchTerms: terms, have: have) }
    }

    /// New songs like yours in a genre (Apple's free search; no Spotify needed).
    func discoverGenre(_ genre: String) {
        var counts: [String: Int] = [:]
        for t in tracks(inGenre: genre) { counts[t.artist, default: 0] += 1 }
        let artists = counts.sorted { $0.value > $1.value }.map(\.key)
        let have = Set(library.tracks.map { songKey(title: $0.title, artist: $0.artist) })
        Task { await discover.find(genre: genre, artists: artists, have: have) }
    }

    /// "Hip-Hop/Rap" → ["hip hop", "rap"]; "R&B/Soul" → ["r&b", "soul"].
    static func spotifyTerms(_ genre: String) -> [String] {
        genre.lowercased().split(separator: "/").map {
            $0.replacingOccurrences(of: "-", with: " ").trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty && $0 != "score" }
    }

    // MARK: Playlists

    func newPlaylist(with ids: [String] = []) {
        playlistPrompt = PlaylistPrompt(renaming: nil, ids: ids, name: "")
    }

    func renamePlaylist(_ list: LibraryPlaylist) {
        playlistPrompt = PlaylistPrompt(renaming: list.id, ids: [], name: list.name)
    }

    func finishPlaylistPrompt() {
        guard let prompt = playlistPrompt else { return }
        playlistPrompt = nil
        if let id = prompt.renaming {
            library.renamePlaylist(id, to: prompt.name)
        } else {
            let id = library.createPlaylist(named: prompt.name, with: prompt.ids)
            if prompt.ids.isEmpty {
                search = ""
                route = .playlist(id)
            } else {
                show("Added \(prompt.ids.count) song\(prompt.ids.count == 1 ? "" : "s") to \(prompt.name.isEmpty ? "New Playlist" : prompt.name)")
            }
        }
    }

    /// Creates (or refreshes) the playlist in the Music app, so it syncs to your iPhone.
    func sendToAppleMusic(_ list: LibraryPlaylist, quiet: Bool = false) {
        let songs = list.tracks.compactMap { t in
            library.url(for: t.id).map { AppleMusicExport.Song(path: $0.path, musicID: library.musicIDs[t.id]) }
        }
        if !quiet { show("Adding “\(list.name)” to Apple Music…", sticky: true) }
        Task {
            switch await AppleMusicExport.send(name: list.name, songs: songs) {
            case .done(let n):
                if !quiet { show("“\(list.name)” is in Apple Music with \(n) song\(n == 1 ? "" : "s").") }
            case .failed(let why): show("Couldn't update Apple Music: \(why)")
            }
        }
    }

    /// Auto-push: collects edited playlists and sends them to Apple Music a
    /// few seconds after the edits stop (one update per burst of changes).
    private func queueAutoPush(_ ids: [String]) {
        guard autoPushToAppleMusic else { return }
        pushQueue.formUnion(ids)
        pushTask?.cancel()
        pushTask = Task {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            let ids = pushQueue
            pushQueue = []
            for list in library.playlists where ids.contains(list.id) && list.editable {
                sendToAppleMusic(list, quiet: true)
            }
        }
    }

    // MARK: Surprise & Guess

    /// Tells the recorder about play/pause/song changes, and keeps Surprise topped up.
    private func listened() {
        let state = session.state
        recorder.observe(id: state.currentID, playing: state.isPlaying) { [library] in library.track($0)?.duration ?? 0 }
        guard state.radio == "surprise", state.queue.count - state.index <= 2 else { return }
        if let next = recommender.surpriseNext(after: state.queue.last, recent: recorder.recent + state.queue,
                                               tracks: library.tracks) {
            session.perform(Command(action: "enqueue", ids: [next]))
        }
    }

    /// Starts Surprise: one song now, more picked as it plays.
    func startSurprise() {
        guard let first = recommender.surpriseNext(after: session.state.currentID, recent: recorder.recent,
                                                   tracks: library.tracks) else { return }
        session.perform(Command(action: "play", ids: [first], index: 0, text: "surprise"))
    }

    /// Rebuilds Guess when the hour changes (or the library first loads).
    func refreshGuess(force: Bool = false) {
        let hour = Calendar.current.component(.hour, from: Date())
        guard force || hour != guessHour || library.forYou.isEmpty else { return }
        guessHour = hour
        library.setForYou(guess: recommender.guess(tracks: library.tracks), moment: Recommender.moment())
    }

    // MARK: Mini player

    /// Hides the big window and shows the small floating player.
    func showMiniPlayer(_ openWindow: OpenWindowAction) {
        openWindow(id: "mini")
        for window in NSApp.windows where window.identifier?.rawValue.hasPrefix("main") == true { window.orderOut(nil) }
    }

    /// Back to the full window.
    func showFullWindow(_ openWindow: OpenWindowAction) {
        if let main = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            main.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.identifier?.rawValue.hasPrefix("mini") == true { window.close() }
    }

    func show(_ message: String, sticky: Bool = false) {
        toast = message
        toastTask?.cancel()
        guard !sticky else { return }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { toast = nil }
        }
    }

    func connectAppleMusic() {
        if let folder = LibraryStore.appleMusicFolder {
            library.add([folder])
        } else {
            importPanel()
        }
    }

    func importPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        panel.message = "Choose music files or folders to add to Musiplex"
        if panel.runModal() == .OK { library.add(panel.urls) }
    }
}

struct PlaylistPrompt: Identifiable {
    let id = UUID()
    var renaming: String?
    var ids: [String]
    var name: String
}

@main
struct MusiplexApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 640)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 800)
        .commands {
            CommandMenu("Playback") {
                Button("Play / Pause") { model.send("toggle") }.keyboardShortcut("p")
                Button("Next") { model.send("next") }.keyboardShortcut(.rightArrow)
                Button("Previous") { model.send("prev") }.keyboardShortcut(.leftArrow)
                Divider()
                Button("Import…") { model.importPanel() }.keyboardShortcut("o")
                Button("Rescan Library") { model.library.rescan() }.keyboardShortcut("r")
                Picker("Crossfade", selection: Binding(get: { model.session.state.crossfade },
                                                       set: { model.send("crossfade", value: $0) })) {
                    Text("Off").tag(0.0)
                    ForEach([2.0, 4, 6, 8, 12], id: \.self) { Text("\(Int($0)) seconds").tag($0) }
                }
                Divider()
                Toggle("Show Notch", isOn: Binding(get: { model.notchEnabled }, set: { model.notchEnabled = $0 }))
            }
        }

        Window("Browser", id: "browser") {
            BrowserView()
                .environment(model)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1100, height: 760)

        Window("Now Playing", id: "mini") {
            MiniPlayerView()
                .environment(model)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.topTrailing)

        MenuBarExtra {
            MenuBarPlayer().environment(model)
        } label: {
            MenuBarIcon().environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}
