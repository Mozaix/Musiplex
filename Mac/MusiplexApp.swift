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
        session.onApplied = { [weak self] in
            self?.notch?.refresh()
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
        notch = NotchController(model: self)
        if let folder = UserDefaults.standard.string(forKey: "notchSnapshot") {
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
    func sendToAppleMusic(_ list: LibraryPlaylist) {
        let songs = list.tracks.compactMap { t in
            library.url(for: t.id).map { AppleMusicExport.Song(path: $0.path, musicID: library.musicIDs[t.id]) }
        }
        show("Adding “\(list.name)” to Apple Music…", sticky: true)
        Task {
            switch await AppleMusicExport.send(name: list.name, songs: songs) {
            case .done(let n): show("“\(list.name)” is in Apple Music with \(n) song\(n == 1 ? "" : "s").")
            case .failed(let why): show("Couldn't add to Apple Music: \(why)")
            }
        }
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
        WindowGroup {
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

        MenuBarExtra {
            MenuBarPlayer().environment(model)
        } label: {
            MenuBarIcon().environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}
