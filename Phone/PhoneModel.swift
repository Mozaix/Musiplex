import ActivityKit
import AVFoundation
import Network
import Observation
import SwiftUI
import UIKit

@MainActor @Observable
final class PhoneModel {
    /// The one model, shared with Siri commands.
    static let shared = PhoneModel()

    /// wifi = home network or Tailscale (streams audio); nearby = Bluetooth /
    /// peer-to-peer (control + downloads, downloaded songs only for audio).
    enum Link: Equatable { case searching, connecting, needsPIN, wifi, nearby, offline }

    private(set) var link: Link = .searching {
        didSet { if link != oldValue { updateRadios() } }
    }
    private(set) var macName = "Mac"
    private(set) var macTracks: [Track] = []
    private(set) var macAlbums: [Playlist] = []
    private(set) var playlists: [Playlist] = []
    private(set) var devices: [DeviceInfo] = []
    private(set) var host: String?
    var showPlayer = false
    /// Hide extra copies of the same song, and never download them.
    private(set) var hideDuplicates = UserDefaults.standard.bool(forKey: "hideDuplicates")
    /// Duplicate track ID → the copy that's kept (always computed, applied when hiding).
    private(set) var duplicates: [String: String] = [:]
    /// Address used away from home, e.g. the Mac's Tailscale IP or MagicDNS name.
    /// The Mac's Tailscale address(es), learned automatically while connected at home.
    private(set) var tailscaleHosts = UserDefaults.standard.stringArray(forKey: "autoHosts") ?? []
    var remoteHost = UserDefaults.standard.string(forKey: "remoteHost") ?? "" {
        didSet { UserDefaults.standard.set(remoteHost, forKey: "remoteHost") }
    }

    let deviceID: String
    let kind = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
    var deviceWord: String { kind == "ipad" ? "iPad" : "iPhone" }
    let session: SessionController
    let downloads = DownloadStore()
    let upcoming = UpcomingCache()
    let appleMusic: AppleMusicSync
    /// On-device taste model (shared with the Mac when connected). Powers Surprise and Guess offline.
    let recommender = Recommender()
    @ObservationIgnored private lazy var recorder = ListeningRecorder(recommender)
    /// Playlist change history from the Mac, newest first.
    private(set) var history: [PlaylistVersion] = []
    /// Keep a Bluetooth link to the Mac open next to Wi‑Fi: commands go over
    /// both, and if Wi‑Fi drops, playback control carries on instantly.
    var bluetoothBackup = UserDefaults.standard.object(forKey: "bluetoothBackup") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(bluetoothBackup, forKey: "bluetoothBackup")
            updateRadios()
            if bluetoothBackup {
                if link == .wifi { nearby.connect() }
            } else if !viaNearby {
                nearby.disconnect()
                hasBackup = false
            }
            // Tell the Mac (it only advertises over Bluetooth when needed).
            if link == .wifi { hello(pin: nil) }
        }
    }
    /// The Bluetooth standby link is up.
    private(set) var hasBackup = false

    var isLinked: Bool { link == .wifi || link == .nearby }

    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private let socketSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.networkServiceType = .responsiveAV
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var lanHost: String?
    @ObservationIgnored private var token = UserDefaults.standard.string(forKey: "token")
    @ObservationIgnored private var byID: [String: Track] = [:]
    @ObservationIgnored private var nowPlaying: NowPlayingBridge?
    @ObservationIgnored private let live = LiveActivityManager()
    @ObservationIgnored private let watch = WatchBridge()
    @ObservationIgnored private let nearby: NearbyClient
    @ObservationIgnored private var viaNearby = false
    @ObservationIgnored private var commandSeq = Int.random(in: 1...1_000_000)
    @ObservationIgnored private var active = true
    @ObservationIgnored private var probing = false
    @ObservationIgnored private var retrying = false
    @ObservationIgnored private let artDir: URL
    @ObservationIgnored private var artWaiters: [String: [CheckedContinuation<Data?, Never>]] = [:]
    @ObservationIgnored private var nearbyQueue: [Track] = []
    @ObservationIgnored private var nearbyInflight: [String: Track] = [:]
    @ObservationIgnored private var rawCatalog = Catalog(tracks: [], albums: [], playlists: [])
    /// Kept song ID → every copy of it (kept + duplicates).
    @ObservationIgnored private var copies: [String: [String]] = [:]
    /// Any copy of a song → the copy that's kept.
    @ObservationIgnored private var canonical: [String: String] = [:]

    init() {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "deviceID") {
            deviceID = saved
        } else {
            deviceID = UUID().uuidString
            defaults.set(deviceID, forKey: "deviceID")
        }
        session = SessionController(device: deviceID)
        appleMusic = AppleMusicSync(defaultOn: UIDevice.current.userInterfaceIdiom == .phone)
        nearby = NearbyClient(name: UIDevice.current.name)

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        artDir = support.appendingPathComponent("art")
        try? FileManager.default.createDirectory(at: artDir, withIntermediateDirectories: true)

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        session.state.activeDevice = deviceID
        session.resolveURL = { [unowned self] id in
            localCopy(id) ?? upcoming.url(for: id) ?? (link == .wifi ? remoteURL("file/\(id).\(track(id)?.ext ?? "m4a")") : nil)
        }
        session.onApplied = { [unowned self] in
            rememberLast()
            publish()
            prefetchUpcoming()
            listenedOffline()
        }
        session.durationOf = { [unowned self] in track($0)?.duration ?? 0 }
        nowPlaying = NowPlayingBridge { [unowned self] in send($0) }
        LiveControl.handler = { [unowned self] in send(Command(action: $0)) }
        watch.onCommand = { [unowned self] in send($0) }
        watch.onResend = { [unowned self] in publish() }

        let artDir = artDir
        ArtCache.shared.loader = { [weak self] id in
            let file = artDir.appendingPathComponent("\(id).jpg")
            if let image = UIImage(contentsOfFile: file.path) { return image }
            guard let data = await self?.artData(id), let image = UIImage(data: data) else { return nil }
            try? data.write(to: file)
            return image
        }

        loadSavedCatalog()

        appleMusic.source = { [unowned self] in
            guard link == .wifi || link == .nearby, !rawCatalog.tracks.isEmpty else { return nil }
            return (rawCatalog.tracks, rawCatalog.playlists, UIDevice.current.name)
        }
        appleMusic.send = { [unowned self] in transmit($0) }

        setUpNearby()
        startBrowsing()
        reconnect()
    }

    // MARK: Lookups

    func track(_ id: String?) -> Track? {
        guard let id else { return nil }
        return byID[id] ?? downloads.track(id)
    }

    func tracks(_ list: Playlist) -> [Track] { list.trackIDs.compactMap { track($0) } }

    var currentTrack: Track? { track(session.state.currentID) }

    /// Songs to browse: the Mac's library when linked, otherwise what's on this device.
    var songs: [Track] { isLinked ? macTracks : downloads.tracks }

    /// Playlists to show. Offline: the saved ones, trimmed to the songs on this device.
    var shownPlaylists: [Playlist] {
        if isLinked { return playlists }
        return playlists.compactMap { list in
            var copy = list
            copy.trackIDs = list.trackIDs.filter { isDownloaded($0) }
            return copy.trackIDs.isEmpty ? nil : copy
        }
    }

    var albums: [Playlist] {
        if isLinked { return macAlbums }
        return Dictionary(grouping: downloads.tracks) { $0.album.lowercased() }
            .map { Playlist(id: $0.key, name: $0.value[0].album, subtitle: $0.value[0].artist, trackIDs: $0.value.map(\.id)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func deviceName(_ id: String) -> String {
        if id == deviceID { return "This \(deviceWord)" }
        return devices.first { $0.id == id }?.name ?? (id == "mac" ? macName : "another device")
    }

    var pickableDevices: [DeviceInfo] {
        isLinked ? devices : [DeviceInfo(id: deviceID, name: UIDevice.current.name, kind: kind)]
    }

    private func remoteURL(_ path: String) -> URL? {
        guard let host, let token else { return nil }
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = host
        comps.port = Net.httpPort
        comps.path = "/" + path
        comps.queryItems = [URLQueryItem(name: "t", value: token)]
        return comps.url
    }

    // MARK: Wi‑Fi / Tailscale link

    private func startBrowsing() {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Net.service, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let ip = results.lazy.compactMap { result -> String? in
                if case .bonjour(let txt) = result.metadata, let ip = txt["ip"], !ip.isEmpty { return ip }
                return nil
            }.first
            Task { @MainActor in
                guard let self, let ip else { return }
                self.lanHost = ip
                self.reconnect()
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func setActive(_ on: Bool) {
        active = on
        if on {
            reconnect()
            appleMusic.schedule()
        }
    }

    /// Probe every known address (home Wi‑Fi first, then the remote/Tailscale
    /// one) and connect to the first that answers. If none do, fall back to
    /// Bluetooth. While on Bluetooth it keeps trying to upgrade to Wi‑Fi.
    func reconnect() {
        guard link != .wifi, link != .needsPIN, !probing else { return }
        guard socket == nil else { return }
        // Test switch (launch with `-nearbyOnly YES`): skip Wi‑Fi to exercise Bluetooth.
        if UserDefaults.standard.bool(forKey: "nearbyOnly") {
            if link != .nearby { link = .connecting }
            nearby.connect()
            return
        }
        var candidates: [String] = []
        let auto = UserDefaults.standard.stringArray(forKey: "autoHosts") ?? []
        for h in [lanHost, UserDefaults.standard.string(forKey: "lastHost"), remoteHost.trimmingCharacters(in: .whitespaces)] + auto {
            if let h, !h.isEmpty, !candidates.contains(h) { candidates.append(h) }
        }
        guard !candidates.isEmpty else {
            if link != .nearby { link = nearby.hasMacNearby ? .connecting : .searching }
            nearby.connect()
            return
        }
        probing = true
        if link != .nearby { link = .connecting }
        Task {
            // Try every address at once (home Wi‑Fi answers in milliseconds,
            // Tailscale over cellular can take a few seconds) and use the first.
            if let found = await firstReachable(candidates) {
                probing = false
                open(found)
                return
            }
            probing = false
            if link != .nearby {
                link = .offline
                nearby.connect()
            }
            retryLater()
        }
    }

    private func retryLater() {
        guard !retrying else { return }
        retrying = true
        Task {
            try? await Task.sleep(for: .seconds(link == .nearby ? 15 : 6))
            retrying = false
            if active, link == .offline || link == .nearby || link == .searching { reconnect() }
        }
    }

    private func firstReachable(_ hosts: [String]) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            for (i, host) in hosts.enumerated() {
                group.addTask {
                    // Give earlier (home) addresses a head start so they win ties.
                    if i > 0 { try? await Task.sleep(for: .milliseconds(150 * i)) }
                    return await Self.ping(host) ? host : nil
                }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
    }

    nonisolated private static func ping(_ host: String) async -> Bool {
        let bracketed = host.contains(":") ? "[\(host)]" : host
        guard let url = URL(string: "http://\(bracketed):\(Net.httpPort)/ping") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return false }
        return String(decoding: data, as: UTF8.self) == "musiplex"
    }

    private func open(_ host: String) {
        socket?.cancel()
        guard let url = URL(string: "ws://\(host):\(Net.wsPort)") else { return }
        if viaNearby {
            // Upgrading from Bluetooth to Wi‑Fi.
            abandonNearbyDownloads()
            nearby.disconnect()
            viaNearby = false
        }
        self.host = host
        var request = URLRequest(url: url)
        request.networkServiceType = .responsiveAV
        let task = socketSession.webSocketTask(with: request)
        task.maximumMessageSize = 8 << 20
        socket = task
        task.resume()
        hello(pin: nil)
        receive(task)
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.socket === task else { return }
                switch result {
                case .failure:
                    self.dropped()
                case .success(let frame):
                    let data: Data? = switch frame {
                    case .data(let d): d
                    case .string(let s): Data(s.utf8)
                    @unknown default: nil
                    }
                    if let data, let message = try? JSONDecoder().decode(Message.self, from: data) {
                        self.handle(message)
                    }
                    self.receive(task)
                }
            }
        }
    }

    // MARK: Nearby (Bluetooth) link

    private func setUpNearby() {
        nearby.onFound = { [weak self] in
            guard let self else { return }
            if self.link == .wifi {
                if self.bluetoothBackup { self.nearby.connect() }   // standby next to Wi‑Fi
                return
            }
            guard !self.isLinked, self.socket == nil, !self.probing else { return }
            self.nearby.connect()
        }
        nearby.onConnect = { [weak self] in
            guard let self else { return }
            guard self.link != .wifi, self.socket == nil else {
                // Already on Wi‑Fi: keep this as a standby link (or drop it).
                if self.bluetoothBackup, self.link == .wifi {
                    self.sendNearby(Message(type: "hello", token: self.token, name: UIDevice.current.name,
                                            deviceID: self.deviceID, kind: self.kind, text: "backup"))
                } else {
                    self.nearby.disconnect()
                }
                return
            }
            self.viaNearby = true
            self.link = .connecting
            self.hello(pin: nil)
        }
        nearby.onDisconnect = { [weak self] in
            guard let self else { return }
            self.hasBackup = false
            guard self.viaNearby else { return }
            self.viaNearby = false
            self.abandonNearbyDownloads()
            if self.link != .wifi { self.dropped() }
        }
        nearby.onData = { [weak self] data in
            guard let self, let message = try? JSONDecoder().decode(Message.self, from: data) else { return }
            if !self.viaNearby {
                // Standby link chatter only.
                if message.type == "backupReady" { self.hasBackup = true }
                if message.type == "promoted" { self.promoteBackup(state: message.state, devices: message.devices) }
                return
            }
            self.handle(message)
        }
        nearby.onProgress = { [weak self] name, value in
            guard let self, name.hasPrefix("file|") else { return }
            self.downloads.setProgress(String(name.dropFirst(5)), value)
        }
        nearby.onResource = { [weak self] name, url in
            self?.received(resource: name, at: url)
        }
    }

    private func received(resource name: String, at url: URL?) {
        if name == "catalog" {
            if let url, let data = try? Data(contentsOf: url), let catalog = try? JSONDecoder().decode(Catalog.self, from: data) {
                apply(catalog)
            }
        } else if name.hasPrefix("art|") {
            let id = String(name.dropFirst(4))
            resolveArt(id, url.flatMap { try? Data(contentsOf: $0) })
        } else if name.hasPrefix("file|") {
            let id = String(name.dropFirst(5))
            if let track = nearbyInflight.removeValue(forKey: id) {
                if let url { downloads.adopt(track, file: url) } else { downloads.cancel(id) }
            }
            pumpNearby()
            return
        }
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    private func pumpNearby() {
        while nearbyInflight.count < 2, !nearbyQueue.isEmpty {
            let track = nearbyQueue.removeFirst()
            guard !isDownloaded(track.id) else {
                downloads.cancel(track.id)
                continue
            }
            nearbyInflight[track.id] = track
            transmit(Message(type: "fetch", ids: [track.id], text: "file"))
        }
    }

    private func abandonNearbyDownloads() {
        for t in nearbyQueue { downloads.cancel(t.id) }
        for id in nearbyInflight.keys { downloads.cancel(id) }
        nearbyQueue = []
        nearbyInflight = [:]
        for id in Array(artWaiters.keys) { resolveArt(id, nil) }
    }

    // MARK: Messages

    private func hello(pin: String?) {
        // seq = 1 tells the Mac this device wants a Bluetooth standby link.
        transmit(Message(type: "hello", token: token, pin: pin, name: UIDevice.current.name, deviceID: deviceID, kind: kind,
                         seq: bluetoothBackup ? 1 : 0))
    }

    /// Bluetooth / peer-to-peer scanning only while it can help: not connected
    /// yet, or keeping a standby link. On Wi‑Fi without standby it's off, so it
    /// can't interfere with streaming.
    private func updateRadios() {
        nearby.setBrowsing(link != .wifi || bluetoothBackup)
    }

    func submit(pin: String) {
        guard socket != nil || nearby.isConnected else { return reconnect() }
        hello(pin: pin)
    }

    private func transmit(_ message: Message) {
        var message = message
        if message.type == "command" {
            commandSeq += 1
            message.seq = commandSeq
        }
        guard let data = try? JSONEncoder().encode(message) else { return }
        if viaNearby {
            nearby.send(data)
        } else {
            socket?.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
            // Belt and braces: commands also go over the Bluetooth standby link
            // (the Mac runs each one once), so a Wi‑Fi hiccup doesn't eat a tap.
            if message.type == "command", hasBackup { nearby.send(data) }
        }
    }

    private func sendNearby(_ message: Message) {
        if let data = try? JSONEncoder().encode(message) { nearby.send(data) }
    }

    /// Wi‑Fi dropped but the Bluetooth standby is up: switch to it without a gap.
    private func promoteBackup(state: SessionState?, devices: [DeviceInfo]?) {
        guard !viaNearby, nearby.isConnected else { return }
        socket?.cancel()
        socket = nil
        viaNearby = true
        hasBackup = false
        link = .nearby
        if let devices { self.devices = devices }
        if let state { session.follow(state) }
        // Make it the main link on the Mac too.
        hello(pin: nil)
        publish()
        retryLater()
    }

    private func handle(_ m: Message) {
        switch m.type {
        case "welcome":
            token = m.token
            UserDefaults.standard.set(m.token, forKey: "token")
            if !viaNearby { UserDefaults.standard.set(host, forKey: "lastHost") }
            if let hosts = m.hosts, !hosts.isEmpty {
                UserDefaults.standard.set(hosts, forKey: "autoHosts")
                tailscaleHosts = hosts
            }
            macName = m.name ?? "Mac"
            devices = m.devices ?? []
            link = viaNearby ? .nearby : .wifi
            ArtCache.shared.resetMisses()
            if let state = m.state { session.follow(state) }
            fetchCatalog()
            // Swap listening history with the Mac (plays made offline go up, the Mac's come down).
            recommender.saveNow()
            transmit(Message(type: "taste", text: String(decoding: recommender.export(), as: UTF8.self)))
            if viaNearby {
                retryLater()
            } else if bluetoothBackup {
                if nearby.isConnected {
                    sendNearby(Message(type: "hello", token: token, name: UIDevice.current.name,
                                       deviceID: deviceID, kind: kind, text: "backup"))
                } else {
                    nearby.connect()
                }
            } else {
                nearby.disconnect()
            }
        case "taste":
            if let text = m.text { recommender.merge(Data(text.utf8)) }
        case "denied":
            link = .needsPIN
        case "state":
            if isLinked, let state = m.state { session.follow(state) }
        case "tick":
            if isLinked { session.tick(position: m.position ?? 0, isPlaying: m.isPlaying ?? false) }
        case "devices":
            devices = m.devices ?? devices
            publish()
        case "library":
            fetchCatalog()
        case "download":
            if let ids = m.ids {
                ids.compactMap { byID[$0] }.forEach(download)
            } else {
                downloadAllMissing()
            }
        case "noArt":
            m.ids?.forEach { resolveArt($0, nil) }
        case "noFile":
            for id in m.ids ?? [] {
                nearbyInflight[id] = nil
                downloads.cancel(id)
            }
            pumpNearby()
        default:
            break
        }
    }

    private func dropped() {
        if !viaNearby, hasBackup, nearby.isConnected {
            promoteBackup(state: nil, devices: nil)
            return
        }
        socket?.cancel()
        socket = nil
        hasBackup = false
        if viaNearby {
            nearby.disconnect()
            viaNearby = false
        }
        abandonNearbyDownloads()
        session.detach()
        link = .offline
        publish()
        if active {
            nearby.connect()
            retryLater()
        }
    }

    private func fetchCatalog() {
        if viaNearby {
            transmit(Message(type: "fetch", text: "catalog"))
            return
        }
        guard let url = remoteURL("catalog") else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else { return }
            apply(catalog)
        }
    }

    /// The last catalog from the Mac, kept so playlists are there offline too.
    private var catalogFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("catalog.json")
    }

    private func loadSavedCatalog() {
        guard let data = try? Data(contentsOf: catalogFile),
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else { return }
        apply(catalog, save: false)
    }

    private func apply(_ catalog: Catalog, save: Bool = true) {
        if save {
            let file = catalogFile
            Task.detached(priority: .utility) {
                if let data = try? JSONEncoder().encode(catalog) { try? data.write(to: file, options: .atomic) }
            }
        }
        rawCatalog = catalog
        history = catalog.history ?? history
        appleMusic.schedule()
        byID = Dictionary(catalog.tracks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        duplicates = findDuplicates(in: catalog.tracks)
        rebuildCopies()
        rebuildLists()
        publish()
    }

    /// Applies (or lifts) duplicate hiding to songs, albums and playlists.
    /// Surprise and Guess. From the Mac while connected; worked out on this device offline.
    var forYou: [Playlist] {
        if isLinked {
            return rawCatalog.playlists.filter { $0.subtitle?.hasPrefix("auto") == true }
        }
        let local = downloads.tracks
        return [
            Playlist(id: "auto-surprise", name: "Surprise", subtitle: "auto", trackIDs: []),
            Playlist(id: "auto-guess", name: "Guess", subtitle: "auto · \(Recommender.moment())",
                     trackIDs: recommender.guess(tracks: local)),
        ]
    }

    // MARK: Siri

    /// Siri may start the app in the background: connect, and wait a moment for it.
    func readyForSiri() async {
        if link != .wifi, link != .nearby { reconnect() }
        var waited = 0
        while link == .searching || link == .connecting, waited < 40 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
    }

    private var lastSaved: String?

    /// Remembers the song (and its album) playing now, for "Play music".
    private func rememberLast() {
        guard let t = currentTrack, t.id != lastSaved else { return }
        lastSaved = t.id
        let d = UserDefaults.standard
        d.set(t.id, forKey: "lastTrackID")
        d.set(t.album, forKey: "lastAlbum")
        d.set(t.artist, forKey: "lastArtist")
    }

    /// The album you last listened to, from the song you were on (Surprise if there's none yet).
    func playLastAlbum() {
        let d = UserDefaults.standard
        guard let lastID = d.string(forKey: "lastTrackID") else { return startSurprise() }
        let name = d.string(forKey: "lastAlbum")?.lowercased()
        let list = albums.first { $0.trackIDs.contains(lastID) }
            ?? albums.first { $0.name.lowercased() == name && name != nil }
        guard let list else { return startSurprise() }
        let songs = isLinked ? tracks(list) : tracks(list).filter { isDownloaded($0.id) }
        guard !songs.isEmpty else { return startSurprise() }
        play(songs, at: songs.firstIndex { $0.id == lastID } ?? 0)
    }

    /// Stops everything: this device, and the Mac too when connected.
    func stopForSiri() {
        send(Command(action: "pause"))
        session.core.setPlaying(false)
    }

    /// Starts Surprise: on the Mac when connected, otherwise from this device's downloads.
    func startSurprise() {
        activateAudio()
        if isLinked {
            send(Command(action: "surprise"))
        } else if let first = recommender.surpriseNext(after: session.state.currentID, recent: recorder.recent,
                                                         tracks: downloads.tracks) {
            session.perform(Command(action: "play", ids: [first], index: 0, text: "surprise"))
        }
    }

    /// Offline (this device is in charge): learn from what plays and keep Surprise topped up.
    private func listenedOffline() {
        guard !session.isFollower else { return }
        let state = session.state
        recorder.observe(id: state.currentID, playing: state.isPlaying) { [unowned self] in track($0)?.duration ?? 0 }
        guard state.radio == "surprise", state.queue.count - state.index <= 2,
              let next = recommender.surpriseNext(after: state.queue.last, recent: recorder.recent + state.queue,
                                                  tracks: downloads.tracks) else { return }
        session.perform(Command(action: "enqueue", ids: [next]))
    }

    private func rebuildLists() {
        var catalog = rawCatalog
        catalog.playlists.removeAll { $0.subtitle?.hasPrefix("auto") == true }
        guard hideDuplicates, !duplicates.isEmpty else {
            macTracks = catalog.tracks
            macAlbums = catalog.albums
            playlists = catalog.playlists
            return
        }
        let dupes = duplicates
        func clean(_ list: Playlist) -> Playlist {
            var seen = Set<String>()
            var copy = list
            copy.trackIDs = list.trackIDs.map { dupes[$0] ?? $0 }.filter { seen.insert($0).inserted }
            return copy
        }
        macTracks = catalog.tracks.filter { dupes[$0.id] == nil }
        macAlbums = catalog.albums.map(clean).filter { !$0.trackIDs.isEmpty }
        playlists = catalog.playlists.map(clean).filter { !$0.trackIDs.isEmpty }
    }

    /// Groups every song (on the Mac or downloaded here) with its other copies,
    /// including copies the Mac has hidden as duplicates.
    private func rebuildCopies() {
        let local = downloads.tracks.filter { byID[$0.id] == nil }
        var all: [String: String] = duplicates
        for (dup, kept) in findDuplicates(in: rawCatalog.tracks + local) where all[dup] == nil && all[kept] == nil {
            all[dup] = kept
        }
        canonical = all
        copies = [:]
        for (dup, kept) in all {
            copies[kept, default: [kept]].append(dup)
            copies[dup, default: [dup]].append(kept)
        }
    }

    /// The file on this device for a song. With duplicates removed, any copy
    /// of the same song counts, so nothing is downloaded twice.
    func localCopy(_ id: String) -> URL? {
        if let url = downloads.localURL(id) { return url }
        for copy in copies[duplicates[id] ?? id] ?? [] {
            // A downloaded copy counts if duplicates are removed, or if the Mac
            // itself no longer lists that copy (it hid it as a duplicate).
            guard hideDuplicates || byID[copy] == nil else { continue }
            if let url = downloads.localURL(copy) { return url }
        }
        return nil
    }

    func isDownloaded(_ id: String) -> Bool { localCopy(id) != nil }

    func setHideDuplicates(_ on: Bool) {
        hideDuplicates = on
        UserDefaults.standard.set(on, forKey: "hideDuplicates")
        rebuildLists()
    }

    private func artData(_ id: String) async -> Data? {
        if link == .wifi, let url = remoteURL("art/\(id)") {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return data
        }
        guard link == .nearby else { return nil }
        return await withCheckedContinuation { continuation in
            let first = artWaiters[id] == nil
            artWaiters[id, default: []].append(continuation)
            guard first else { return }
            transmit(Message(type: "fetch", ids: [id], text: "art"))
            Task {
                try? await Task.sleep(for: .seconds(10))
                resolveArt(id, nil)
            }
        }
    }

    private func resolveArt(_ id: String, _ data: Data?) {
        artWaiters.removeValue(forKey: id)?.forEach { $0.resume(returning: data) }
    }

    // MARK: Playback

    /// Sends a command to the Mac when linked; otherwise plays locally.
    func send(_ command: Command) {
        if isLinked {
            transmit(Message(type: "command", command: command))
            // Don't wait for the round trip: pause/play this device right away.
            if session.isAudibleHere, session.state.currentID != nil {
                let playing: Bool? = switch command.action {
                case "toggle": !session.state.isPlaying
                case "pause": false
                case "resume": true
                default: nil
                }
                if let playing {
                    session.state.isPlaying = playing
                    session.core.setPlaying(playing)
                }
            }
        } else {
            activateAudio()
            session.perform(command)
        }
    }

    func send(_ action: String, value: Double? = nil, text: String? = nil) {
        send(Command(action: action, value: value, text: text))
    }

    func play(_ tracks: [Track], at index: Int) {
        guard tracks.indices.contains(index) else { return }
        activateAudio()
        if isLinked {
            send(Command(action: "play", ids: tracks.map(\.id), index: index))
        } else {
            // Offline: only what's on this device can play.
            let local = tracks.filter { isDownloaded($0.id) }
            guard let i = local.firstIndex(of: tracks[index]) else { return }
            session.perform(Command(action: "play", ids: local.map(\.id), index: i))
        }
    }

    private func activateAudio() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    // MARK: Playlists (saved on the Mac)

    /// Playlists made in Musiplex, which can be added to.
    var editablePlaylists: [Playlist] { playlists.filter { $0.subtitle == "mine" || $0.id.hasPrefix("my-") } }

    func isEditable(_ list: Playlist) -> Bool { list.subtitle == "mine" || list.id.hasPrefix("my-") }

    func removeFromPlaylist(_ ids: [String], playlistID: String) {
        transmit(Message(type: "playlist", text: playlistID, removeIDs: ids))
    }

    func renamePlaylist(_ playlistID: String, to name: String) {
        transmit(Message(type: "playlist", name: name, text: playlistID))
    }

    /// Saves a new playlist order on the Mac (shown on every device).
    func reorderPlaylists(_ ids: [String]) {
        // Show it straight away; the Mac's catalog confirms it.
        let rank = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        playlists.sort { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) }
        transmit(Message(type: "reorderPlaylists", ids: ids))
    }

    /// Asks the Mac to undo one version of your playlists.
    func revert(_ version: PlaylistVersion) {
        transmit(Message(type: "revert", text: String(version.number)))
    }

    func deletePlaylist(_ playlistID: String) {
        transmit(Message(type: "deletePlaylist", text: playlistID))
    }

    /// Song IDs waiting for a name for a new playlist.
    var newPlaylistIDs: [String]?

    func addToPlaylist(_ ids: [String], playlistID: String) {
        transmit(Message(type: "playlist", ids: ids, text: playlistID))
    }

    func createPlaylist(named name: String, with ids: [String]) {
        transmit(Message(type: "playlist", name: name, ids: ids))
    }

    func sendToAppleMusic(_ playlistID: String) {
        transmit(Message(type: "exportPlaylist", text: playlistID))
    }

    // MARK: Downloads

    func download(_ track: Track) {
        // With duplicates removed, fetch the kept copy instead (once).
        var track = track
        if hideDuplicates, let kept = duplicates[track.id], let keeper = byID[kept] { track = keeper }
        guard !isDownloaded(track.id), !downloads.isBusy(track.id) else { return }
        if link == .wifi, let url = remoteURL("file/\(track.id).\(track.ext)") {
            downloads.download(track, from: url)
        } else if link == .nearby {
            downloads.markQueued(track.id)
            nearbyQueue.append(track)
            pumpNearby()
        }
    }

    func download(_ tracks: [Track]) { tracks.forEach(download) }

    func missing(in tracks: [Track]) -> [Track] {
        var seen = Set<String>()
        return tracks.filter { t in
            let id = hideDuplicates ? (duplicates[t.id] ?? t.id) : t.id
            return seen.insert(id).inserted && !isDownloaded(id) && !downloads.isBusy(id)
        }
    }

    var missing: [Track] { missing(in: macTracks) }

    func downloadAllMissing() { download(missing) }

    /// Downloaded songs that are extra copies of a song already on this device.
    var extraCopies: [String] {
        var groups: [String: [String]] = [:]
        for id in downloads.ids { groups[canonical[id] ?? id, default: []].append(id) }
        var extra: [String] = []
        for (kept, ids) in groups where ids.count > 1 {
            let keep = ids.contains(kept) ? kept : ids.sorted()[0]
            extra += ids.filter { $0 != keep }
        }
        return extra.filter { $0 != session.state.currentID }
    }

    /// Makes this device match the Mac without duplicates: removes extra
    /// copies of the same song, then downloads (once) every song that's missing.
    /// Songs that are on this device but not on the Mac are left alone.
    @discardableResult
    func sync() -> (removed: Int, added: Int) {
        if !hideDuplicates { setHideDuplicates(true) }
        let extra = extraCopies
        if !extra.isEmpty {
            downloads.remove(extra)
            rebuildCopies()
        }
        let todo = missing
        download(todo)
        return (extra.count, todo.count)
    }

    /// Removes every downloaded song from this device. If one is playing from
    /// the local file, playback stops.
    func deleteAllDownloads() {
        abandonNearbyDownloads()
        if !isLinked { session.perform(Command(action: "pause")) }
        downloads.removeAll()
    }

    func stopDownloads() {
        abandonNearbyDownloads()
        downloads.cancelAll()
    }

    /// Keeps the next few songs in the queue ready on this device.
    private func prefetchUpcoming() {
        guard upcoming.enabled, link == .wifi else { return }
        let state = session.state
        guard !state.queue.isEmpty else { return }
        var next: [Track] = []
        var i = state.index + 1
        while next.count < upcoming.count, i < state.queue.count + (state.repeatMode == .all ? state.queue.count : 0) {
            let id = state.queue[i % state.queue.count]
            if let t = track(id), !isDownloaded(id), id != state.currentID { next.append(t) }
            i += 1
            if i - state.index > 50 { break }
        }
        upcoming.keep(next, current: state.currentID) { [unowned self] t in remoteURL("file/\(t.id).\(t.ext)") }
    }

    // MARK: System surfaces

    private func publish() {
        let state = session.state
        let track = currentTrack
        if state.currentID != nil { activateAudio() }
        let position = session.livePosition
        nowPlaying?.update(track: track, position: position, playing: state.isPlaying)

        let audible = isLinked ? state.activeDevice : deviceID
        let audibleInfo = audible == deviceID ? DeviceInfo(id: deviceID, name: deviceWord, kind: kind)
            : devices.first { $0.id == audible } ?? DeviceInfo(id: "mac", name: "Mac", kind: "mac")
        live.update(track: track, position: position, playing: state.isPlaying,
                    deviceName: audibleInfo.kind == "mac" ? "Mac" : audibleInfo.name, deviceSymbol: audibleInfo.symbol)

        var context: [String: Any] = [
            "title": track?.title ?? "", "artist": track?.artist ?? "", "id": track?.id ?? "",
            "duration": track?.duration ?? 0, "playing": state.isPlaying, "linked": isLinked,
            "macName": macName, "active": audible, "volume": state.volume, "shuffle": state.shuffle,
            "devices": pickableDevices.map { ["id": $0.id, "name": $0.id == deviceID ? "This \(deviceWord)" : $0.name, "kind": $0.kind] },
        ]
        if let id = track?.id, let image = ArtCache.shared.cached(id), let thumb = LiveActivityManager.thumbnail(image, side: 96, limit: 9000) {
            context["art"] = thumb
        }
        watch.update(context, position: position, playing: state.isPlaying)

        // Artwork loads lazily; refresh the lock screen / island / watch once it's in.
        if let id = track?.id, ArtCache.shared.cached(id) == nil {
            Task {
                if await ArtCache.shared.image(id) != nil, session.state.currentID == id { publish() }
            }
        }
    }
}

/// Keeps one Live Activity (lock screen + Dynamic Island) in step with playback.
/// It only pushes an update when something visible actually changed — the
/// progress bar animates on its own from a timestamp.
@MainActor
final class LiveActivityManager {
    private var activity: Activity<MusiplexAttributes>?
    private var last: MusiplexAttributes.ContentState?
    private var thumb: (id: String, data: Data)?

    init() {
        // Clear anything left over from a previous run.
        for stale in Activity<MusiplexAttributes>.activities {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }
    }

    func update(track: Track?, position: Double, playing: Bool, deviceName: String, deviceSymbol: String) {
        guard let track, ActivityAuthorizationInfo().areActivitiesEnabled else {
            if let activity {
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
                self.activity = nil
                last = nil
            }
            return
        }
        if thumb?.id != track.id, let image = ArtCache.shared.cached(track.id), let data = Self.thumbnail(image, side: 64, limit: 1500) {
            thumb = (track.id, data)
        }
        let state = MusiplexAttributes.ContentState(
            title: track.title, artist: track.artist, isPlaying: playing, duration: track.duration,
            position: position, asOf: Date(), deviceName: deviceName, deviceSymbol: deviceSymbol,
            art: thumb?.id == track.id ? thumb?.data : nil)

        if let last, activity != nil, last.title == state.title, last.artist == state.artist,
           last.isPlaying == playing, last.deviceName == deviceName, last.art == state.art {
            let expected = last.position + (last.isPlaying ? Date().timeIntervalSince(last.asOf) : 0)
            if abs(expected - position) < 2 { return }
        }
        last = state
        let content = ActivityContent(state: state, staleDate: nil)
        if let activity {
            Task { await activity.update(content) }
        } else {
            activity = try? Activity.request(attributes: MusiplexAttributes(), content: content, pushType: nil)
        }
    }

    static func thumbnail(_ image: UIImage, side: CGFloat, limit: Int) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: side, height: side)
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        for quality in [0.6, 0.4, 0.25, 0.15] {
            if let data = small.jpegData(compressionQuality: quality), data.count < limit { return data }
        }
        return nil
    }
}
