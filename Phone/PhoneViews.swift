import SwiftUI

@main
struct MusiplexPhoneApp: App {
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var delegate
    @State private var model = PhoneModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            PhoneRoot()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .onChange(of: phase) { _, new in model.setActive(new == .active) }
    }
}

enum PhoneTab: String, CaseIterable, Identifiable {
    case songs = "Songs", albums = "Albums", playlists = "Playlists", downloaded = "Downloaded"
    var id: String { rawValue }
}

enum PhoneRoute: Hashable {
    case album(String)
    case playlist(String)
}

struct PhoneRoot: View {
    @Environment(PhoneModel.self) private var model
    @State private var tab = PhoneTab.songs
    @State private var search = ""
    @State private var showLink = false
    @State private var path: [PhoneRoute] = []
    @State private var newPlaylistName = ""
    @State private var confirmDeleteAll = false
    @State private var syncResult: (removed: Int, added: Int)?

    private var syncTitle: String {
        guard let r = syncResult else { return "" }
        return r.removed == 0 && r.added == 0 ? "Already in sync" : "Syncing with \(model.macName)"
    }

    private var syncMessage: String {
        guard let r = syncResult else { return "" }
        var parts: [String] = []
        if r.added > 0 { parts.append("Downloading \(r.added) new song\(r.added == 1 ? "" : "s").") }
        if r.removed > 0 { parts.append("Removed \(r.removed) duplicate cop\(r.removed == 1 ? "y" : "ies") from this \(model.deviceWord).") }
        if parts.isEmpty { parts.append("Every song on your Mac is on this \(model.deviceWord), with no duplicates.") }
        return parts.joined(separator: " ")
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header
                    Picker("", selection: $tab) {
                        ForEach(PhoneTab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16).padding(.bottom, 12)

                    if tab != .playlists {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass").foregroundStyle(Theme.dim)
                            TextField("Search", text: $search).autocorrectionDisabled()
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(.horizontal, 16).padding(.bottom, 10)
                    }

                    if tab != .downloaded { DownloadAllBanner() }

                    content
                }
                .padding(.bottom, 100)
            }
            .scrollDismissesKeyboard(.immediately)
            .background(Theme.bg.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: PhoneRoute.self) { route in
                switch route {
                case .album(let id):
                    if let album = model.albums.first(where: { $0.id == id }) {
                        CollectionScreen(list: album, kind: "Album")
                    }
                case .playlist(let id):
                    if let list = model.playlists.first(where: { $0.id == id }) {
                        CollectionScreen(list: list, kind: "Playlist")
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if model.currentTrack != nil {
                MiniPlayer().onTapGesture { model.showPlayer = true }
            }
        }
        .sheet(isPresented: $model.showPlayer) {
            NowPlayingView().presentationDragIndicator(.visible)
        }
        .alert("New Playlist", isPresented: Binding(get: { model.newPlaylistIDs != nil }, set: { if !$0 { model.newPlaylistIDs = nil } })) {
            TextField("Playlist name", text: $newPlaylistName)
            Button("Create") {
                model.createPlaylist(named: newPlaylistName.isEmpty ? "New Playlist" : newPlaylistName, with: model.newPlaylistIDs ?? [])
                model.newPlaylistIDs = nil
                newPlaylistName = ""
            }
            Button("Cancel", role: .cancel) { newPlaylistName = "" }
        } message: {
            Text("It's saved on your Mac and shows up on all your devices.")
        }
        .sheet(isPresented: $showLink) {
            LinkSheet().presentationDetents([.medium, .large])
        }
        .onChange(of: model.link) { _, link in
            if link == .needsPIN { showLink = true }
            if !model.isLinked, model.macTracks.isEmpty, !model.downloads.tracks.isEmpty { tab = .downloaded }
        }
    }

    private func matches(_ t: Track) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || t.title.localizedCaseInsensitiveContains(q) || t.artist.localizedCaseInsensitiveContains(q)
            || t.album.localizedCaseInsensitiveContains(q)
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .songs:
            DuplicatesRow()
            let tracks = model.songs.filter(matches)
            if tracks.isEmpty { EmptyState(tab: tab) }
            TrackRows(tracks: tracks)
        case .albums:
            let q = search.trimmingCharacters(in: .whitespaces)
            let albums = model.albums.filter {
                q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) || ($0.subtitle ?? "").localizedCaseInsensitiveContains(q)
            }
            if albums.isEmpty { EmptyState(tab: tab) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 14)], spacing: 18) {
                ForEach(albums) { album in
                    NavigationLink(value: PhoneRoute.album(album.id)) {
                        AlbumTile(list: album)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        case .playlists:
            if model.isLinked {
                Button { model.newPlaylistIDs = [] } label: {
                    Label("New Playlist", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 16).padding(.bottom, 10)
            }
            if model.playlists.isEmpty { EmptyState(tab: tab) }
            ForEach(model.playlists) { list in
                NavigationLink(value: PhoneRoute.playlist(list.id)) {
                    PlaylistRow(list: list)
                }
                .buttonStyle(.plain)
            }
        case .downloaded:
            let tracks = model.downloads.tracks.filter(matches)
            if !model.downloads.tracks.isEmpty {
                HStack {
                    Text("\(model.downloads.tracks.count) songs · \(ByteCountFormatter.string(fromByteCount: model.downloads.totalBytes, countStyle: .file)) on this \(model.deviceWord)")
                        .font(.footnote).foregroundStyle(Theme.dim)
                    Spacer()
                    if model.isLinked {
                        Button { syncResult = model.sync() } label: {
                            Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                                .font(.footnote.weight(.semibold))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Theme.accent.opacity(0.18), in: Capsule())
                                .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                    Button(role: .destructive) { confirmDeleteAll = true } label: {
                        Label("Delete All", systemImage: "trash")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Color.red.opacity(0.15), in: Capsule())
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16).padding(.bottom, 8)
                .confirmationDialog("Delete all \(model.downloads.tracks.count) downloaded songs from this \(model.deviceWord)?",
                                    isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                    Button("Delete All Songs", role: .destructive) { model.deleteAllDownloads() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("They stay on your Mac, so you can download them again any time.")
                }
                .alert(syncTitle, isPresented: Binding(get: { syncResult != nil }, set: { if !$0 { syncResult = nil } })) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(syncMessage)
                }
            }
            if tracks.isEmpty { EmptyState(tab: tab) }
            TrackRows(tracks: tracks)
        }
    }

    private var header: some View {
        HStack {
            Text("Musiplex").font(.largeTitle.bold())
            Spacer()
            Button { showLink = true } label: {
                HStack(spacing: 6) {
                    if model.link == .nearby {
                        Image(systemName: "dot.radiowaves.left.and.right").font(.caption).foregroundStyle(Theme.accent)
                    } else {
                        Circle().fill(model.link == .wifi ? Color.green : Color.gray).frame(width: 8, height: 8)
                    }
                    Text(linkLabel).font(.footnote.weight(.semibold)).lineLimit(1)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Theme.raised, in: Capsule())
                .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 14)
    }

    private var linkLabel: String {
        switch model.link {
        case .wifi: model.macName
        case .nearby: "\(model.macName) · Bluetooth"
        case .connecting: "Connecting…"
        case .searching: "Searching…"
        case .needsPIN: "Enter PIN"
        case .offline: "Offline"
        }
    }
}

struct EmptyState: View {
    @Environment(PhoneModel.self) private var model
    let tab: PhoneTab

    var body: some View {
        let (icon, title, text): (String, String, String) = switch tab {
        case .downloaded:
            ("arrow.down.circle", "Nothing downloaded yet",
             "Tap the arrow next to a song, album or playlist — or Download Everything — to keep music on this \(model.deviceWord).")
        case .playlists:
            ("music.note.list", model.isLinked ? "No playlists" : "Not connected",
             model.isLinked ? "Playlists from Apple Music on your Mac, and .m3u files in imported folders, show up here."
                 : "Connect to your Mac to see your playlists.")
        default:
            model.isLinked
                ? ("music.note", "Nothing here", "No songs match.")
                : ("laptopcomputer.and.iphone", "Not connected to your Mac",
                   "Open Musiplex on your Mac. It connects by itself over home Wi‑Fi or Bluetooth; away from home, turn on Tailscale.")
        }
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(Theme.gradient)
            Text(title).font(.headline)
            Text(text).font(.subheadline).foregroundStyle(Theme.dim).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32).padding(.vertical, 60)
    }
}

/// "Remove Duplicates": hides extra copies of the same song on this device and
/// makes sure only one copy is ever downloaded. Nothing on the Mac changes.
struct DuplicatesRow: View {
    @Environment(PhoneModel.self) private var model
    @State private var confirm = false

    var body: some View {
        let count = model.duplicates.count
        if model.isLinked, count > 0 {
            HStack(spacing: 10) {
                Image(systemName: "square.on.square.dashed").foregroundStyle(Theme.accent)
                Text(model.hideDuplicates ? "\(count) duplicate\(count == 1 ? "" : "s") removed" : "\(count) duplicate song\(count == 1 ? "" : "s")")
                    .font(.subheadline)
                Spacer()
                Button(model.hideDuplicates ? "Show" : "Remove Duplicates") {
                    if model.hideDuplicates { model.setHideDuplicates(false) } else { confirm = true }
                }
                .font(.subheadline.weight(.semibold))
            }
            .padding(12)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 16).padding(.bottom, 10)
            .alert("Remove \(count) duplicate\(count == 1 ? "" : "s")?", isPresented: $confirm) {
                Button("Remove") { model.setHideDuplicates(true) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The best-quality copy of each song stays, and duplicates won't be downloaded. Nothing is deleted from your Mac, and you can show them again any time.")
            }
        }
    }
}

/// "Download Everything": pulls every song on the Mac that isn't on this device yet.
struct DownloadAllBanner: View {
    @Environment(PhoneModel.self) private var model

    var body: some View {
        let busy = model.downloads.progress.count
        let missing = model.isLinked ? model.missing.count : 0
        if busy > 0 {
            HStack(spacing: 12) {
                ProgressView().tint(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Downloading \(busy) song\(busy == 1 ? "" : "s")…").font(.subheadline.weight(.semibold))
                    Group {
                        if model.link == .nearby {
                            Text("Over Bluetooth — keep the devices close")
                        } else if model.downloads.speed > 0 {
                            Text("\(ByteCountFormatter.string(fromByteCount: Int64(model.downloads.speed), countStyle: .file))/s · keep Musiplex open for full speed")
                        } else {
                            Text("Keep Musiplex open for full speed")
                        }
                    }
                    .font(.caption).foregroundStyle(Theme.dim)
                }
                Spacer()
                Button("Stop") { model.stopDownloads() }.font(.subheadline.weight(.semibold))
            }
            .padding(12)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 16).padding(.bottom, 10)
        } else if missing > 0 {
            Button { model.sync() } label: {
                Label("Sync with Mac · \(missing) new song\(missing == 1 ? "" : "s")", systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 11)
                    .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(.black)
            }
            .padding(.horizontal, 16).padding(.bottom, 10)
        }
    }
}

struct TrackRows: View {
    @Environment(PhoneModel.self) private var model
    let tracks: [Track]

    var body: some View {
        let state = model.session.state
        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
            PhoneRow(track: track, current: state.currentID == track.id, playing: state.isPlaying)
                .contentShape(Rectangle())
                .onTapGesture { model.play(tracks, at: index) }
        }
    }
}

struct AlbumTile: View {
    @Environment(PhoneModel.self) private var model
    let list: Playlist

    var body: some View {
        let tracks = model.tracks(list)
        let done = !tracks.isEmpty && tracks.allSatisfy { model.isDownloaded($0.id) }
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(id: list.trackIDs.first, radius: 10)
                .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
                .overlay(alignment: .bottomTrailing) {
                    if done {
                        Image(systemName: "checkmark.circle.fill").font(.title3)
                            .foregroundStyle(.white, Theme.accent).padding(6)
                    }
                }
            Text(list.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(list.subtitle ?? "").font(.caption).foregroundStyle(Theme.dim).lineLimit(1)
        }
    }
}

struct PlaylistRow: View {
    @Environment(PhoneModel.self) private var model
    let list: Playlist

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(id: list.trackIDs.first, radius: 8).frame(width: 60, height: 60)
            VStack(alignment: .leading, spacing: 3) {
                Text(list.name).font(.body.weight(.semibold)).lineLimit(1)
                Text("\(list.trackIDs.count) songs").font(.footnote).foregroundStyle(Theme.dim)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.dim)
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

/// An album or playlist page, with Play, Shuffle and Download buttons.
struct CollectionScreen: View {
    @Environment(PhoneModel.self) private var model
    let list: Playlist
    let kind: String
    @State private var tint = Color.clear
    @State private var sentToMusic = false

    var body: some View {
        let tracks = model.tracks(list)
        let missing = model.missing(in: tracks)
        let busy = tracks.contains { model.downloads.isBusy($0.id) }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 14) {
                    ArtworkView(id: list.trackIDs.first, radius: 12)
                        .frame(maxWidth: 260)
                        .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
                    VStack(spacing: 4) {
                        Text(list.name).font(.title2.bold()).multilineTextAlignment(.center)
                        Text([list.subtitle, "\(tracks.count) songs"].compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(Theme.dim)
                    }
                    HStack(spacing: 12) {
                        Button { model.play(tracks, at: 0) } label: {
                            Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity).padding(.vertical, 11)
                                .background(Theme.gradient, in: Capsule()).foregroundStyle(.black)
                        }
                        Button {
                            if !model.session.state.shuffle { model.send("shuffle") }
                            model.play(tracks, at: Int.random(in: 0..<max(tracks.count, 1)))
                        } label: {
                            Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity).padding(.vertical, 11)
                                .background(Theme.raised, in: Capsule()).foregroundStyle(.white)
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: 420)

                    Group {
                        if busy {
                            Label("Downloading…", systemImage: "arrow.down.circle.dotted").foregroundStyle(Theme.dim)
                        } else if missing.isEmpty {
                            Label("On this \(model.deviceWord)", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                        } else if model.isLinked {
                            Button { model.download(missing) } label: {
                                Label(missing.count == tracks.count ? "Download \(kind)" : "Download \(missing.count) More",
                                      systemImage: "arrow.down.circle")
                            }
                        }
                    }
                    .font(.subheadline.weight(.semibold))

                    if model.isLinked {
                        HStack(spacing: 18) {
                            Menu {
                                PhoneAddToPlaylistMenu(ids: list.trackIDs, title: "Add All to Playlist")
                            } label: {
                                Label("Add to Playlist", systemImage: "text.badge.plus")
                            }
                            if kind == "Playlist", !list.id.hasPrefix("am-"), !list.trackIDs.isEmpty {
                                Button {
                                    model.sendToAppleMusic(list.id)
                                    sentToMusic = true
                                } label: {
                                    Label(sentToMusic ? "Sent to Apple Music" : "Add to Apple Music",
                                          systemImage: sentToMusic ? "checkmark" : "applelogo")
                                }
                                .disabled(sentToMusic)
                            }
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 18)

                TrackRows(tracks: tracks)
            }
            .padding(.bottom, 100)
        }
        .background(
            LinearGradient(colors: [tint.opacity(0.55), Theme.bg], startPoint: .top, endPoint: .center).ignoresSafeArea()
        )
        .navigationBarTitleDisplayMode(.inline)
        .task(id: list.id) {
            let color = await ArtCache.shared.tint(list.trackIDs.first)
            withAnimation(.easeInOut(duration: 0.6)) { tint = color }
        }
    }
}

struct PhoneRow: View {
    @Environment(PhoneModel.self) private var model
    let track: Track
    let current: Bool
    let playing: Bool

    var body: some View {
        let downloaded = model.isDownloaded(track.id)
        let progress = model.downloads.progress[track.id]
        let playable = downloaded || model.isLinked
        HStack(spacing: 12) {
            ArtworkView(id: track.id, radius: 6).frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if current, playing {
                        Image(systemName: "waveform").symbolEffect(.variableColor.iterative)
                            .font(.caption).foregroundStyle(Theme.accent)
                    }
                    Text(track.title).lineLimit(1).foregroundStyle(current ? Theme.accent : .white)
                }
                Text(track.artist).font(.footnote).foregroundStyle(Theme.dim).lineLimit(1)
            }
            Spacer(minLength: 8)
            Group {
                if downloaded {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                } else if let progress {
                    ZStack {
                        Circle().stroke(Color.white.opacity(0.15), lineWidth: 3)
                        Circle().trim(from: 0, to: max(0.03, progress))
                            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 20, height: 20)
                } else if model.isLinked {
                    Button { model.download(track) } label: {
                        Image(systemName: "arrow.down.circle").foregroundStyle(Theme.dim)
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.title3)
            .frame(width: 32, height: 32)
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
        .opacity(playable ? 1 : 0.4)
        .contextMenu {
            if downloaded {
                Button("Remove Download", systemImage: "trash", role: .destructive) { model.downloads.remove(track.id) }
            } else if model.isLinked {
                Button("Download", systemImage: "arrow.down.circle") { model.download(track) }
            }
            if model.isLinked {
                Button("Play Next", systemImage: "text.insert") { model.send(Command(action: "playNext", ids: [track.id])) }
                Button("Add to Queue", systemImage: "text.append") { model.send(Command(action: "enqueue", ids: [track.id])) }
                PhoneAddToPlaylistMenu(ids: [track.id])
            }
        }
    }
}

struct MiniPlayer: View {
    @Environment(PhoneModel.self) private var model

    var body: some View {
        let state = model.session.state
        let track = model.currentTrack
        let audible = model.isLinked ? state.activeDevice : model.deviceID
        HStack(spacing: 12) {
            ArtworkView(id: track?.id, radius: 6).frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text(track?.title ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
                Label(audible == model.deviceID ? "Playing on this \(model.deviceWord)" : "Playing on \(model.deviceName(audible))",
                      systemImage: audible == "mac" ? "laptopcomputer" : (audible == model.deviceID ? model.kind == "ipad" ? "ipad" : "iphone" : "iphone"))
                    .font(.caption2.weight(.medium)).foregroundStyle(Theme.accent).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { model.send("toggle") } label: {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill").font(.title3).frame(width: 40, height: 40)
            }
            Button { model.send("next") } label: {
                Image(systemName: "forward.fill").frame(width: 36, height: 40)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.08)))
        .frame(maxWidth: 640)
        .padding(.horizontal, 10).padding(.bottom, 6)
        .contentShape(Rectangle())
    }
}

struct NowPlayingView: View {
    @Environment(PhoneModel.self) private var model
    @State private var tint = Color.clear

    var body: some View {
        let session = model.session
        let state = session.state
        let track = model.currentTrack
        let linked = model.isLinked
        let audible = linked ? state.activeDevice : model.deviceID
        ZStack {
            LinearGradient(colors: [tint.opacity(0.75), Theme.bg], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack(spacing: 22) {
                Spacer(minLength: 12)
                ArtworkView(id: track?.id, radius: 14)
                    .frame(maxWidth: 440)
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
                    .padding(.horizontal, 8)
                    .scaleEffect(state.isPlaying ? 1 : 0.9)
                    .animation(.spring(duration: 0.4), value: state.isPlaying)

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track?.title ?? "—").font(.title2.bold()).lineLimit(1)
                        Text(track?.artist ?? "").font(.body).foregroundStyle(Theme.dim).lineLimit(1)
                    }
                    Spacer()
                    if let track {
                        if model.isDownloaded(track.id) {
                            Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(Theme.accent)
                        } else if model.downloads.isBusy(track.id) {
                            ProgressView()
                        } else if linked {
                            Button { model.download(track) } label: {
                                Image(systemName: "arrow.down.circle").font(.title2).foregroundStyle(.white)
                            }
                        }
                    }
                }

                ScrubBar(duration: track?.duration ?? 0, position: { session.livePosition },
                         onSeek: { model.send("seek", value: $0) }, playing: state.isPlaying)

                HStack {
                    control("shuffle", size: 20, active: state.shuffle) { model.send("shuffle") }
                    Spacer()
                    control("backward.fill", size: 28) { model.send("prev") }
                    Spacer()
                    Button { model.send("toggle") } label: {
                        Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 28, weight: .bold)).foregroundStyle(.black)
                            .frame(width: 72, height: 72).background(.white, in: Circle())
                    }
                    Spacer()
                    control("forward.fill", size: 28) { model.send("next") }
                    Spacer()
                    control(state.repeatMode == .one ? "repeat.1" : "repeat", size: 20,
                            active: state.repeatMode != .off) { model.send("repeat") }
                }
                .buttonStyle(.plain)

                // Which device is audible. Every other one mirrors silently.
                VStack(spacing: 10) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(model.pickableDevices) { device in
                                chip(device, selected: audible == device.id) { model.send("device", text: device.id) }
                            }
                        }
                        .padding(4)
                    }
                    .background(Color.black.opacity(0.3), in: Capsule())

                    if linked, audible == "mac" {
                        HStack(spacing: 10) {
                            Image(systemName: "speaker.fill")
                            Slider(value: Binding(get: { state.volume }, set: { model.send("volume", value: $0) }))
                                .tint(.white)
                            Image(systemName: "speaker.wave.3.fill")
                        }
                        .font(.footnote).foregroundStyle(Theme.dim)
                    }
                    Text(hint(audible: audible, track: track))
                        .font(.caption2).foregroundStyle(Theme.dim).multilineTextAlignment(.center)
                }
                Spacer(minLength: 8)
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 26)
        }
        .task(id: state.currentID) {
            let color = await ArtCache.shared.tint(state.currentID)
            withAnimation(.easeInOut(duration: 0.8)) { tint = color }
        }
    }

    private func hint(audible: String, track: Track?) -> String {
        guard model.isLinked else { return "Offline · playing downloads" }
        if model.link == .nearby, let track, !model.isDownloaded(track.id) {
            return "Over Bluetooth only downloaded songs play on this \(model.deviceWord)"
        }
        if audible == model.deviceID { return "Sound is on this \(model.deviceWord) · other devices mirror, muted" }
        return "Sound is on \(model.deviceName(audible)) · this \(model.deviceWord) is mirroring, muted"
    }

    private func control(_ name: String, size: CGFloat, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: size, weight: .semibold))
                .foregroundStyle(active ? Theme.accent : .white)
                .frame(width: 48, height: 48).contentShape(Rectangle())
        }
    }

    private func chip(_ device: DeviceInfo, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(device.id == model.deviceID ? "This \(model.deviceWord)" : device.name, systemImage: device.symbol)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .foregroundStyle(selected ? .black : .white)
                .background(selected ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.clear), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct LinkSheet: View {
    @Environment(PhoneModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section("Status") {
                    HStack {
                        Circle().fill(model.isLinked ? Color.green : Color.gray).frame(width: 9, height: 9)
                        Text(status)
                        Spacer()
                        if let host = model.host, model.link == .wifi {
                            Text(host).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                if model.link == .needsPIN {
                    Section {
                        TextField("6‑digit PIN", text: $pin)
                            .keyboardType(.numberPad)
                            .onChange(of: pin) { _, new in
                                let digits = String(new.filter(\.isNumber).prefix(6))
                                if digits != new { pin = digits }
                            }
                        Button("Pair") { model.submit(pin: pin) }.disabled(pin.count < 6)
                    } header: {
                        Text("Pair with your Mac")
                    } footer: {
                        Text("The PIN is shown in the bottom‑left corner of Musiplex on your Mac. You only need it once.")
                    }
                }
                Section {
                    TextField("100.x.y.z or mac-name.tailnet.ts.net", text: $model.remoteHost)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Connect") { model.reconnect() }
                        .disabled(model.link == .wifi || model.link == .needsPIN)
                    if !model.tailscaleHosts.isEmpty {
                        LabeledContent("Found automatically") {
                            Text(model.tailscaleHosts.joined(separator: "\n"))
                                .font(.footnote.monospacedDigit()).multilineTextAlignment(.trailing)
                        }
                    }
                } header: {
                    Text("Away from home (Tailscale)")
                } footer: {
                    Text(model.tailscaleHosts.isEmpty
                         ? "Turn on Tailscale on your Mac and this \(model.deviceWord), then connect once at home — Musiplex learns the Mac's Tailscale address by itself. Or type it here."
                         : "Away from home, just turn on Tailscale on this \(model.deviceWord) and open Musiplex. Leave the box empty unless you want to use a different address.")
                }
                Section {
                    Picker("Crossfade", selection: Binding(get: { model.session.state.crossfade },
                                                           set: { model.send("crossfade", value: $0) })) {
                        Text("Off").tag(0.0)
                        ForEach([2.0, 4, 6, 8, 12], id: \.self) { Text("\(Int($0)) seconds").tag($0) }
                    }
                    Toggle("Cache upcoming songs", isOn: Binding(get: { model.upcoming.enabled },
                                                                 set: { model.upcoming.enabled = $0 }))
                    if model.upcoming.enabled {
                        Stepper("Keep next \(model.upcoming.count) songs ready", value: Binding(
                            get: { model.upcoming.count }, set: { model.upcoming.count = $0 }), in: 1...10)
                    }
                } header: {
                    Text("Playback")
                } footer: {
                    Text("Crossfade blends each song into the next, on every device. Caching quietly saves the next few songs while streaming from your Mac, so songs change instantly even on weak Wi‑Fi. Cached songs don't count as downloads.")
                }
                Section {
                    Label("Home Wi‑Fi — found automatically", systemImage: "wifi")
                    Label("Bluetooth — when there's no Wi‑Fi, if your Mac is nearby", systemImage: "dot.radiowaves.left.and.right")
                } header: {
                    Text("Other ways to connect")
                } footer: {
                    Text("Over Bluetooth you can control playback and download songs (keep the devices close — it's slower than Wi‑Fi). Songs that aren't downloaded can only stream over Wi‑Fi or Tailscale.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .onChange(of: model.link) { _, link in
                if model.isLinked, !pin.isEmpty { dismiss() }
            }
        }
    }

    private var status: String {
        switch model.link {
        case .wifi: "Connected to \(model.macName)"
        case .nearby: "Connected to \(model.macName) over Bluetooth"
        case .connecting: "Connecting…"
        case .searching: "Looking for your Mac…"
        case .needsPIN: "Waiting for PIN"
        case .offline: "Offline"
        }
    }
}

/// "Add to Playlist": a new playlist, or one you made. Saved on the Mac.
struct PhoneAddToPlaylistMenu: View {
    @Environment(PhoneModel.self) private var model
    let ids: [String]
    var title = "Add to Playlist"

    var body: some View {
        if model.isLinked {
            Menu {
                Button("New Playlist…", systemImage: "plus") { model.newPlaylistIDs = ids }
                ForEach(model.editablePlaylists) { list in
                    Button(list.name) { model.addToPlaylist(ids, playlistID: list.id) }
                }
            } label: {
                Label(title, systemImage: "text.badge.plus")
            }
        }
    }
}
