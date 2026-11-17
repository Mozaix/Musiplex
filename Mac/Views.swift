import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var tint = Color.clear

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Sidebar()
                MainView(tint: tint)
                if model.showQueue { QueuePanel() }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            PlayerBar()
        }
        .background(Theme.bg)
        .ignoresSafeArea()
        .task(id: model.session.state.currentID) {
            let color = await ArtCache.shared.tint(model.session.state.currentID)
            withAnimation(.easeInOut(duration: 0.9)) { tint = color }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.library.add(urls)
            return true
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast)
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 104)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { model.toast = nil }
            }
        }
        .animation(.spring(duration: 0.35), value: model.toast)
        .alert(model.playlistPrompt?.renaming == nil ? "New Playlist" : "Rename Playlist",
               isPresented: Binding(get: { model.playlistPrompt != nil }, set: { if !$0 { model.playlistPrompt = nil } })) {
            TextField("Playlist name", text: Binding(get: { model.playlistPrompt?.name ?? "" },
                                                     set: { model.playlistPrompt?.name = $0 }))
            Button(model.playlistPrompt?.renaming == nil ? "Create" : "Rename") { model.finishPlaylistPrompt() }
            Button("Cancel", role: .cancel) { model.playlistPrompt = nil }
        }
    }
}

// MARK: Sidebar

struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 30, height: 30)
                    .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text("Musiplex").font(.system(size: 19, weight: .bold))
            }
            .padding(.top, 34)
            .padding(.bottom, 18)
            .padding(.horizontal, 8)

            nav("Home", "house.fill", .home)
            nav("Songs", "music.note", .songs)
            nav("Albums", "square.stack.fill", .albums)
            nav("Artists", "music.mic", .artists)
            nav("Settings", "gearshape.fill", .settings)

            Text("LIBRARY").font(.caption2.weight(.semibold)).foregroundStyle(Theme.dim)
                .padding(.top, 22).padding(.horizontal, 10).padding(.bottom, 4)

            if !model.library.appleMusicConnected {
                action("Connect Apple Music", "applelogo") { model.connectAppleMusic() }
            }
            action("Import Files or Folder…", "plus") { model.importPanel() }

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    do {
                        HStack {
                            Text("PLAYLISTS").font(.caption2.weight(.semibold)).foregroundStyle(Theme.dim)
                            Spacer()
                            Button { model.newPlaylist() } label: {
                                Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.dim)
                            .help("New Playlist")
                        }
                        .padding(.top, 12).padding(.horizontal, 10).padding(.bottom, 4)
                        if !model.library.playlists.contains(where: \.editable) {
                            Button { model.newPlaylist() } label: {
                                Label("Create Playlist", systemImage: "plus.rectangle.on.rectangle")
                                    .font(.callout).padding(.horizontal, 10).padding(.vertical, 4)
                                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.accent)
                        }
                        ForEach(model.library.playlists) { list in
                            let selected = model.route == .playlist(list.id) && model.search.isEmpty
                            Button {
                                model.search = ""
                                model.route = .playlist(list.id)
                            } label: {
                                HStack(spacing: 10) {
                                    ArtworkView(id: list.artID, radius: 4).frame(width: 26, height: 26)
                                    Text(list.name).lineLimit(1).font(.callout)
                                    Spacer(minLength: 0)
                                    if !list.editable {
                                        Image(systemName: list.id.hasPrefix("am-") ? "applelogo" : "doc.text")
                                            .font(.system(size: 9)).foregroundStyle(Theme.dim.opacity(0.6))
                                    }
                                }
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .foregroundStyle(selected ? .white : Theme.dim)
                                .background(selected ? Theme.raised : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu { PlaylistMenu(list: list) }
                            // Drag a playlist onto another to put it there.
                            .draggable(PlaylistDrag(id: list.id)) {
                                Text(list.name).padding(6).background(Theme.raised, in: RoundedRectangle(cornerRadius: 6))
                            }
                            .dropDestination(for: PlaylistDrag.self) { items, _ in
                                guard let moved = items.first, moved.id != list.id else { return false }
                                withAnimation(.snappy) { model.library.movePlaylist(moved.id, before: list.id) }
                                return true
                            }
                        }
                        Text("FOLDERS").font(.caption2.weight(.semibold)).foregroundStyle(Theme.dim)
                            .padding(.top, 12).padding(.horizontal, 10).padding(.bottom, 4)
                    }
                    ForEach(model.library.sources, id: \.self) { source in
                        HStack(spacing: 8) {
                            Image(systemName: "folder.fill").font(.caption).foregroundStyle(Theme.accent)
                            Text((source as NSString).lastPathComponent).lineLimit(1).font(.callout)
                                .foregroundStyle(Theme.dim)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .help(source)
                        .contextMenu {
                            Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: source) }
                            Button("Remove from Library") { model.library.remove(source: source) }
                        }
                    }
                }
            }

            Spacer(minLength: 0)
            DevicesCard()
        }
        .padding(10)
        .frame(width: 236)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func nav(_ title: String, _ icon: String, _ route: Route) -> some View {
        let selected = model.route == route && model.search.isEmpty
        return Button {
            model.search = ""
            model.route = route
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 20)
                Text(title).fontWeight(.semibold)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .foregroundStyle(selected ? .white : Theme.dim)
            .background(selected ? Theme.raised : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func action(_ title: String, _ icon: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 20)
                Text(title)
                Spacer()
            }
            .font(.callout)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .foregroundStyle(Theme.dim)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct DevicesCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let server = model.server
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(server.error == nil ? Color.green : Color.red).frame(width: 7, height: 7)
                Text(server.error == nil ? "Server running" : "Server error").font(.caption.weight(.semibold))
            }
            if let error = server.error {
                Text(error).font(.caption2).foregroundStyle(Theme.dim)
            } else {
                row("Wi‑Fi", server.address)
                tailscaleRow
                row("Pairing PIN", server.pin)
            }
            ForEach(server.phones) { phone in
                let audible = model.session.state.activeDevice == phone.deviceID
                HStack(spacing: 8) {
                    Image(systemName: phone.info.symbol).foregroundStyle(Theme.accent).frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(phone.name).font(.caption.weight(.semibold)).lineLimit(1)
                        Text((audible ? "Playing out loud" : "Mirroring · muted") + (phone.nearby ? " · Bluetooth" : ""))
                            .font(.caption2).foregroundStyle(Theme.dim).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button { model.server.push(nil, to: phone.deviceID) } label: {
                        Image(systemName: "arrow.down.circle.fill").font(.system(size: 15))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .help("Download all music to \(phone.name)")
                }
            }
            if let nearbyError = server.nearbyError {
                Label(nearbyError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if server.phones.isEmpty, server.error == nil {
                Text("Open Musiplex on your iPhone or iPad to connect — over Wi‑Fi, Tailscale or Bluetooth.")
                    .font(.caption2).foregroundStyle(Theme.dim)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder private var tailscaleRow: some View {
        let remote = model.remote
        Button { model.search = ""; model.route = .settings } label: {
            HStack {
                Text("Tailscale").foregroundStyle(Theme.dim)
                Spacer()
                if let ip = remote.tailscaleIP {
                    Text(ip).monospacedDigit()
                } else {
                    Label(remote.status == .turningOn ? "Turning on…" : remote.status == .notInstalled ? "Not installed" : "Off",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Remote access settings")
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.dim)
            Spacer()
            Text(value).monospacedDigit().textSelection(.enabled)
        }
        .font(.caption)
    }
}

// MARK: Main area

struct MainView: View {
    @Environment(AppModel.self) private var model
    let tint: Color

    var body: some View {
        @Bindable var model = model
        ZStack(alignment: .top) {
            LinearGradient(colors: [tint.opacity(0.5), tint.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: 360)
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    if case .album = model.route { back(.albums) }
                    if case .artist = model.route { back(.artists) }
                    if case .playlist = model.route { back(.home) }
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Theme.dim)
                        TextField("Search songs, artists, albums", text: $model.search).textFieldStyle(.plain)
                        if !model.search.isEmpty {
                            Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(Theme.dim)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color.black.opacity(0.35), in: Capsule())
                    .frame(maxWidth: 380)
                    Spacer()
                    if model.library.scanning {
                        ProgressView().controlSize(.small)
                        Text(model.library.scanStatus).font(.caption).foregroundStyle(Theme.dim)
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 14)

                ScrollView {
                    content.padding(.horizontal, 24).padding(.bottom, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func back(_ route: Route) -> some View {
        Button { model.route = route } label: {
            Image(systemName: "chevron.left").font(.system(size: 13, weight: .bold))
                .frame(width: 30, height: 30).background(Color.black.opacity(0.35), in: Circle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var content: some View {
        let library = model.library
        if !model.search.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Results").font(.system(size: 26, weight: .bold))
                if model.searchResults.isEmpty {
                    Text("Nothing matches “\(model.search)”.").foregroundStyle(Theme.dim)
                } else {
                    TrackList(tracks: model.searchResults)
                }
            }
        } else {
            switch model.route {
            case .home:
                HomeView()
            case .songs:
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Songs").font(.system(size: 26, weight: .bold))
                        Text("\(library.tracks.count)").font(.title3).foregroundStyle(Theme.dim)
                        Spacer()
                        DuplicateButtons()
                    }
                    if library.tracks.isEmpty { EmptyLibrary() } else { TrackList(tracks: library.tracks) }
                }
            case .albums:
                VStack(alignment: .leading, spacing: 14) {
                    Text("Albums").font(.system(size: 26, weight: .bold))
                    if library.albums.isEmpty { EmptyLibrary() } else { AlbumGrid(albums: library.albums) }
                }
            case .artists:
                VStack(alignment: .leading, spacing: 14) {
                    Text("Artists").font(.system(size: 26, weight: .bold))
                    if library.artists.isEmpty { EmptyLibrary() } else { ArtistGrid(artists: library.artists) }
                }
            case .album(let id):
                if let album = library.albums.first(where: { $0.id == id }) {
                    CollectionView(kind: "Album", title: album.title, subtitle: album.artist,
                                   artID: album.artID, tracks: album.tracks, round: false)
                }
            case .artist(let name):
                if let artist = library.artists.first(where: { $0.name == name }) {
                    CollectionView(kind: "Artist", title: artist.name, subtitle: nil,
                                   artID: artist.artID, tracks: artist.tracks, round: true)
                }
            case .settings:
                SettingsView()
            case .playlist(let id):
                if let list = library.playlists.first(where: { $0.id == id }) {
                    CollectionView(playlist: list, kind: "Playlist", title: list.name, subtitle: nil,
                                   artID: list.artID, tracks: list.tracks, round: false)
                }
            }
        }
    }
}

struct HomeView: View {
    @Environment(AppModel.self) private var model

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }

    var body: some View {
        let library = model.library
        VStack(alignment: .leading, spacing: 26) {
            Text(greeting).font(.system(size: 30, weight: .bold))
            if library.tracks.isEmpty {
                EmptyLibrary()
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    ForEach(library.recentAlbums.prefix(6)) { QuickTile(album: $0) }
                }
                if !library.playlists.isEmpty {
                    Text("Your playlists").font(.title2.bold())
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 8)], spacing: 8) {
                        ForEach(library.playlists) { list in
                            Card(title: list.name, subtitle: "\(list.tracks.count) songs", artID: list.artID, round: false,
                                 play: { model.play(list.tracks) }, open: { model.route = .playlist(list.id) })
                        }
                    }
                    .padding(.horizontal, -10)
                }
                Text("Recently added").font(.title2.bold())
                AlbumGrid(albums: Array(library.recentAlbums.prefix(24)))
            }
        }
    }
}

struct EmptyLibrary: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.note.list").font(.system(size: 44)).foregroundStyle(Theme.gradient)
            Text("Your library is empty").font(.title2.bold())
            Text("Connect your Apple Music folder, import files, or drop them anywhere on this window.")
                .foregroundStyle(Theme.dim).multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Connect Apple Music") { model.connectAppleMusic() }.buttonStyle(PillButton(filled: true))
                Button("Import…") { model.importPanel() }.buttonStyle(PillButton(filled: false))
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
    }
}

/// "Remove Duplicates" hides extra copies of the same song from Musiplex.
/// Nothing is deleted from disk or from the Music app.
struct DuplicateButtons: View {
    @Environment(AppModel.self) private var model
    @State private var found: [String: String]?

    var body: some View {
        let library = model.library
        HStack(spacing: 10) {
            if !library.hidden.isEmpty {
                Button("Show \(library.hidden.count) Hidden") { library.restoreHidden() }
                    .buttonStyle(PillButton(filled: false))
                    .help("Bring back the duplicates you removed")
            }
            Button {
                found = library.findDuplicates()
            } label: {
                Label("Remove Duplicates", systemImage: "square.on.square.dashed")
            }
            .buttonStyle(PillButton(filled: false))
            .disabled(library.tracks.isEmpty)
        }
        .alert(alertTitle, isPresented: Binding(get: { found != nil }, set: { if !$0 { found = nil } })) {
            if let found, !found.isEmpty {
                Button("Remove \(found.count)") { library.hideDuplicates(found) }
                Button("Cancel", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: {
            if let found, !found.isEmpty {
                Text("The best-quality copy of each song is kept. The others are only removed from Musiplex — your files and Apple Music library aren't touched, and you can bring them back any time.")
            } else {
                Text("Every song in your library is unique.")
            }
        }
    }

    private var alertTitle: String {
        guard let found, !found.isEmpty else { return "No duplicates found" }
        return found.count == 1 ? "Found 1 duplicate song" : "Found \(found.count) duplicate songs"
    }
}

struct PillButton: ButtonStyle {
    let filled: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 20).padding(.vertical, 10)
            .foregroundStyle(filled ? .black : .white)
            .background(filled ? AnyShapeStyle(Color.white) : AnyShapeStyle(Theme.raised), in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

struct QuickTile: View {
    @Environment(AppModel.self) private var model
    let album: Album
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(id: album.artID, radius: 0).frame(width: 56, height: 56)
            Text(album.title).font(.callout.weight(.semibold)).lineLimit(2)
            Spacer(minLength: 0)
            if hover {
                PlayCircle(size: 36) { model.play(album.tracks) }.padding(.trailing, 10)
            }
        }
        .background(Color.white.opacity(hover ? 0.16 : 0.09))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { model.route = .album(album.id) }
    }
}

struct PlayCircle: View {
    let size: CGFloat
    var icon = "play.fill"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: size, height: size)
                .background(Theme.gradient, in: Circle())
                .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
    }
}

struct AlbumGrid: View {
    @Environment(AppModel.self) private var model
    let albums: [Album]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 8)], spacing: 8) {
            ForEach(albums) { album in
                Card(title: album.title, subtitle: album.artist, artID: album.artID, round: false,
                     play: { model.play(album.tracks) }, open: { model.route = .album(album.id) })
            }
        }
        .padding(.horizontal, -10)
    }
}

struct ArtistGrid: View {
    @Environment(AppModel.self) private var model
    let artists: [Artist]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 8)], spacing: 8) {
            ForEach(artists) { artist in
                Card(title: artist.name, subtitle: "\(artist.tracks.count) songs", artID: artist.artID, round: true,
                     play: { model.play(artist.tracks) }, open: { model.route = .artist(artist.name) })
            }
        }
        .padding(.horizontal, -10)
    }
}

struct Card: View {
    let title: String
    let subtitle: String
    let artID: String?
    let round: Bool
    let play: () -> Void
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkView(id: artID, radius: round ? 400 : 8)
                .shadow(color: .black.opacity(0.45), radius: 10, y: 6)
                .overlay(alignment: .bottomTrailing) {
                    PlayCircle(size: 44, action: play)
                        .padding(8)
                        .opacity(hover ? 1 : 0)
                        .offset(y: hover ? 0 : 8)
                }
            Text(title).font(.callout.weight(.semibold)).lineLimit(1)
            Text(subtitle).font(.caption).foregroundStyle(Theme.dim).lineLimit(1)
        }
        .padding(10)
        .background(hover ? Theme.raised : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.18), value: hover)
        .onHover { hover = $0 }
        .onTapGesture(perform: open)
    }
}

struct CollectionView: View {
    @Environment(AppModel.self) private var model
    var playlist: LibraryPlaylist? = nil
    let kind: String
    let title: String
    let subtitle: String?
    let artID: String?
    let tracks: [Track]
    let round: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .bottom, spacing: 22) {
                ArtworkView(id: artID, radius: round ? 400 : 8)
                    .frame(width: 200, height: 200)
                    .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
                VStack(alignment: .leading, spacing: 8) {
                    Text(kind).font(.caption.weight(.semibold))
                    Text(title).font(.system(size: 46, weight: .heavy)).lineLimit(2).minimumScaleFactor(0.5)
                    HStack(spacing: 6) {
                        if let subtitle { Text(subtitle).fontWeight(.semibold) }
                        Text("\(subtitle == nil ? "" : "· ")\(tracks.count) songs · \(timeString(tracks.reduce(0) { $0 + $1.duration }))")
                            .foregroundStyle(Theme.dim)
                    }
                    .font(.callout)
                }
            }
            HStack(spacing: 18) {
                PlayCircle(size: 52) { model.play(tracks) }
                Button {
                    if !model.session.state.shuffle { model.send("shuffle") }
                    model.play(tracks, at: Int.random(in: 0..<max(tracks.count, 1)))
                } label: {
                    Image(systemName: "shuffle").font(.title2).foregroundStyle(Theme.dim)
                }
                .buttonStyle(.plain)
                if !model.server.phones.isEmpty {
                    Menu {
                        ForEach(model.server.phones) { phone in
                            Button("Download to \(phone.name)", systemImage: phone.info.symbol) {
                                model.server.push(tracks.map(\.id), to: phone.deviceID)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.down.circle").font(.title2).foregroundStyle(Theme.dim)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Download to a device")
                }
                Menu {
                    if let playlist {
                        PlaylistMenu(list: playlist)
                        Divider()
                    }
                    AddToPlaylistMenu(ids: tracks.map(\.id), title: "Add All to Playlist")
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title2).foregroundStyle(Theme.dim)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                if let playlist, !playlist.id.hasPrefix("am-"), !playlist.tracks.isEmpty {
                    Button { model.sendToAppleMusic(playlist) } label: {
                        Label("Add to Apple Music", systemImage: "applelogo")
                    }
                    .buttonStyle(PillButton(filled: false))
                }
            }
            if let playlist, playlist.editable, tracks.isEmpty {
                Text("This playlist is empty. Right-click any song and choose Add to Playlist → \(playlist.name).")
                    .foregroundStyle(Theme.dim)
            }
            TrackList(tracks: tracks, playlistID: playlist?.editable == true ? playlist?.id : nil)
        }
    }
}

// MARK: Track list

struct TrackList: View {
    @Environment(AppModel.self) private var model
    let tracks: [Track]
    /// Set when showing one of your playlists, so rows can be removed from it.
    var playlistID: String? = nil

    var body: some View {
        let state = model.session.state
        LazyVStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                TrackRow(index: index, track: track, current: state.currentID == track.id,
                         playing: state.isPlaying, playlistID: playlistID) {
                    model.play(tracks, at: index)
                }
            }
        }
        .padding(.horizontal, -12)
    }
}

struct TrackRow: View {
    @Environment(AppModel.self) private var model
    let index: Int
    let track: Track
    let current: Bool
    let playing: Bool
    var playlistID: String? = nil
    let play: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                if hover {
                    Button { current ? model.send("toggle") : play() } label: {
                        Image(systemName: current && playing ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.plain)
                } else if current && playing {
                    Image(systemName: "waveform").symbolEffect(.variableColor.iterative).foregroundStyle(Theme.accent)
                } else {
                    Text("\(index + 1)").monospacedDigit().foregroundStyle(current ? Theme.accent : Theme.dim)
                }
            }
            .frame(width: 30)
            ArtworkView(id: track.id, radius: 4).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).foregroundStyle(current ? Theme.accent : .white).lineLimit(1)
                Text(track.artist).font(.caption).foregroundStyle(Theme.dim).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(track.album).font(.callout).foregroundStyle(Theme.dim).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(timeString(track.duration)).font(.callout.monospacedDigit()).foregroundStyle(Theme.dim)
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(hover ? Theme.raised : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2, perform: play)
        .contextMenu {
            Button("Play") { play() }
            Button("Play Next") { model.session.perform(Command(action: "playNext", ids: [track.id])) }
            Button("Add to Queue") { model.session.perform(Command(action: "enqueue", ids: [track.id])) }
            AddToPlaylistMenu(ids: [track.id])
            if let playlistID {
                Button("Remove from This Playlist") { model.library.remove(track.id, fromPlaylist: playlistID) }
            }
            Divider()
            Button("Show in Finder") {
                if let url = model.library.url(for: track.id) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
    }
}

// MARK: Queue

struct QueuePanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let state = model.session.state
        let upcoming = Array(state.queue.enumerated().dropFirst(state.index + 1).prefix(60))
        VStack(alignment: .leading, spacing: 0) {
            Text("Queue").font(.title3.bold()).padding(.top, 34).padding(.horizontal, 16).padding(.bottom, 14)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if let track = model.currentTrack {
                        label("Now playing")
                        row(track, highlight: true) {}
                    }
                    if !upcoming.isEmpty { label("Next up") }
                    ForEach(upcoming, id: \.offset) { index, id in
                        if let track = model.library.track(id) {
                            row(track, highlight: false) {
                                model.session.perform(Command(action: "jump", index: index))
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .frame(width: 280)
        .frame(maxHeight: .infinity)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .transition(.move(edge: .trailing))
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(Theme.dim)
            .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 4)
    }

    private func row(_ track: Track, highlight: Bool, tap: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            ArtworkView(id: track.id, radius: 4).frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.callout).foregroundStyle(highlight ? Theme.accent : .white).lineLimit(1)
                Text(track.artist).font(.caption).foregroundStyle(Theme.dim).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .contentShape(Rectangle())
        .onTapGesture(perform: tap)
    }
}

// MARK: Playlist menus

/// "Add to Playlist" submenu: a new playlist, or any of yours.
struct AddToPlaylistMenu: View {
    @Environment(AppModel.self) private var model
    let ids: [String]
    var title = "Add to Playlist"

    var body: some View {
        Menu(title) {
            Button("New Playlist…") { model.newPlaylist(with: ids) }
            let mine = model.library.playlists.filter(\.editable)
            if !mine.isEmpty { Divider() }
            ForEach(mine) { list in
                Button(list.name) { model.library.add(ids, toPlaylist: list.id) }
            }
        }
    }
}

/// Rename / Delete / Add to Apple Music for one playlist.
struct PlaylistMenu: View {
    @Environment(AppModel.self) private var model
    let list: LibraryPlaylist

    var body: some View {
        if !list.id.hasPrefix("am-"), !list.tracks.isEmpty {
            Button("Add to Apple Music") { model.sendToAppleMusic(list) }
        }
        if list.editable {
            Button("Rename…") { model.renamePlaylist(list) }
            Button("Delete Playlist", role: .destructive) {
                if model.route == .playlist(list.id) { model.route = .home }
                model.library.deletePlaylist(list.id)
            }
        }
    }
}


/// A playlist being dragged to a new spot in the sidebar.
struct PlaylistDrag: Codable, Transferable {
    var id: String
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .data)
    }
}
