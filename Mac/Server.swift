import Foundation
import MultipeerConnectivity
import Network
import Observation

/// Connects phones and iPads to this Mac:
/// - WebSocket control channel + HTTP file server, over Wi‑Fi or Tailscale
/// - MultipeerConnectivity "nearby" link (Bluetooth / peer-to-peer Wi‑Fi) when
///   there's no shared network
@MainActor @Observable
final class Server {
    struct Client: Identifiable {
        let id = UUID()
        var name = "iPhone"
        var kind = "iphone"
        var deviceID = ""
        var authed = false
        /// A second, standby link from a device already connected another way
        /// (Bluetooth next to Wi‑Fi). Commands may arrive on both; if the main
        /// link drops, this one takes over instantly.
        var backup = false
        /// This device keeps a Bluetooth standby link next to Wi‑Fi.
        var wantsBackup = false
        let conn: NWConnection?
        let peer: MCPeerID?

        var nearby: Bool { peer != nil }
        var info: DeviceInfo { DeviceInfo(id: deviceID, name: name, kind: kind) }
    }

    private(set) var clients: [Client] = []
    private(set) var address = "—"
    /// This Mac's Tailscale address (100.64.0.0/10), for connecting from afar.
    private(set) var tailscale: String?
    private(set) var error: String?
    /// Set when macOS blocks the nearby (Bluetooth / peer-to-peer) link.
    private(set) var nearbyError: String?
    let pin: String
    let macName = Host.current().localizedName ?? "Mac"

    var phones: [Client] { clients.filter { $0.authed && !$0.backup } }
    /// Phones and iPads you can pick as the speaker (not a linked server's live link).
    var listeners: [Client] { phones.filter { $0.kind != "server" } }

    /// Every device that can be picked as the speaker, this Mac first.
    /// (A linked server's live link, kind "server", follows along but is never a speaker.)
    var devices: [DeviceInfo] {
        [DeviceInfo(id: "mac", name: macName, kind: "mac")] + listeners.map(\.info)
    }

    /// The key a linked server (the laptop) uses to pass your phones through to this Mac.
    var chainToken: String { token }

    func name(of deviceID: String) -> String {
        devices.first { $0.id == deviceID }?.name ?? "another device"
    }

    static func isTailscale(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    /// Asks the app to add a playlist to Apple Music (sent from a phone).
    @ObservationIgnored var onExport: ((String) -> Void)?
    /// A device asked to start Surprise.
    @ObservationIgnored var onSurprise: (() -> Void)?
    /// A device sent its listening history (plays made offline).
    @ObservationIgnored var onTaste: ((Data) -> Void)?
    /// This Mac's listening history, sent to devices so their offline Guess knows you.
    @ObservationIgnored var tasteData: (() -> Data)?
    @ObservationIgnored private let token: String
    @ObservationIgnored private let http: HTTPServer
    @ObservationIgnored private let nearby: NearbyHost
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var magicDNS: String?
    /// Recent command numbers per device, so a command sent over two links runs once.
    @ObservationIgnored private var seenSeqs: [String: [Int]] = [:]
    @ObservationIgnored private var catalogData = Data()
    @ObservationIgnored private unowned let library: LibraryStore
    @ObservationIgnored private unowned let session: SessionController

    init(library: LibraryStore, session: SessionController) {
        self.library = library
        self.session = session
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "token"), let savedPin = defaults.string(forKey: "pin") {
            token = saved
            pin = savedPin
        } else {
            token = (0..<4).map { _ in String(UInt64.random(in: 0 ... .max), radix: 36) }.joined()
            pin = String(format: "%06d", Int.random(in: 0...999_999))
            defaults.set(token, forKey: "token")
            defaults.set(pin, forKey: "pin")
        }
        http = HTTPServer(token: token, artDir: library.artDir)
        nearby = NearbyHost(name: Host.current().localizedName ?? "Mac")
    }

    func start() {
        libraryChanged(notify: false)
        let all = Self.localIPs()
        let ip = all.first { !Self.isTailscale($0) && !$0.hasPrefix("169.254.") }
        address = ip ?? "No network"
        tailscale = all.first(where: Self.isTailscale)
        Task.detached(priority: .utility) {
            let name = Self.tailscaleName()
            await MainActor.run { self.magicDNS = name }
        }
        do {
            try http.start(port: Net.httpPort)
            // No Nagle: small control messages (pause, skip) go out immediately.
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            let params = NWParameters(tls: nil, tcp: tcp)
            // Not on peer-to-peer Wi‑Fi: keeping that link busy makes Wi‑Fi hop
            // channels, which causes audio dropouts.
            params.serviceClass = .interactiveVoice
            let ws = NWProtocolWebSocket.Options()
            ws.autoReplyPing = true
            ws.maximumMessageSize = 8 << 20
            params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: UInt16(Net.wsPort))!)
            listener.service = NWListener.Service(
                name: macName, type: Net.service,
                txtRecord: NWTXTRecord(["ip": ip ?? "", "http": "\(Net.httpPort)", "ws": "\(Net.wsPort)"]))
            listener.newConnectionHandler = { [weak self] conn in
                MainActor.assumeIsolated { self?.accept(conn) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    if case .failed(let e) = state { self?.error = e.localizedDescription }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            self.error = "Couldn't start server: \(error.localizedDescription)"
        }

        nearby.onConnect = { [weak self] peer in
            guard let self, !self.clients.contains(where: { $0.peer == peer }) else { return }
            self.clients.append(Client(name: peer.displayName, conn: nil, peer: peer))
        }
        nearby.onDisconnect = { [weak self] peer in
            guard let self, let client = self.clients.first(where: { $0.peer == peer }) else { return }
            self.drop(client.id)
        }
        nearby.onData = { [weak self] data, peer in
            guard let self, let client = self.clients.first(where: { $0.peer == peer }),
                  let message = try? JSONDecoder().decode(Message.self, from: data) else { return }
            self.handle(message, from: client.id)
        }
        nearby.onError = { [weak self] in
            self?.nearbyError = "Bluetooth sharing is off: allow Musiplex in System Settings → Privacy & Security → Local Network, then reopen Musiplex."
        }
        nearby.start()
    }

    func libraryChanged(notify: Bool = true) {
        catalogData = (try? JSONEncoder().encode(library.catalog)) ?? Data()
        http.update(paths: library.paths, library: catalogData)
        if notify { phones.forEach { send(Message(type: "library"), to: $0) } }
    }

    func broadcast(_ state: SessionState) {
        let targets = phones
        guard !targets.isEmpty else { return }
        let message = Message(type: "state", state: state)
        targets.forEach { send(message, to: $0) }
    }

    /// Ask a device to download songs (nil = everything it doesn't have yet).
    func push(_ ids: [String]?, to deviceID: String) {
        guard let client = phones.first(where: { $0.deviceID == deviceID }) else { return }
        send(Message(type: "download", ids: ids), to: client)
    }

    // MARK: Connections

    private func accept(_ conn: NWConnection) {
        let client = Client(conn: conn, peer: nil)
        clients.append(client)
        let id = client.id
        conn.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed, .cancelled: self?.drop(id)
                default: break
                }
            }
        }
        conn.start(queue: .main)
        receive(id, conn)
    }

    private func receive(_ id: UUID, _ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, context, _, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                if error != nil || meta?.opcode == .close || (data == nil && context == nil) {
                    conn.cancel()
                    self.drop(id)
                    return
                }
                if let data, !data.isEmpty, let message = try? JSONDecoder().decode(Message.self, from: data) {
                    self.handle(message, from: id)
                }
                self.receive(id, conn)
            }
        }
    }

    private func handle(_ m: Message, from id: UUID) {
        guard let i = clients.firstIndex(where: { $0.id == id }) else { return }
        switch m.type {
        case "hello":
            guard m.token == token || m.pin == pin else {
                send(Message(type: "denied"), to: clients[i])
                return
            }
            let deviceID = m.deviceID ?? UUID().uuidString
            if m.text == "backup" {
                // Standby link: keep the main connection, just remember this one.
                for old in clients where old.deviceID == deviceID && old.backup && old.id != id {
                    clients.removeAll { $0.id == old.id }
                }
                guard let j = clients.firstIndex(where: { $0.id == id }) else { return }
                clients[j].authed = true
                clients[j].backup = true
                clients[j].deviceID = deviceID
                clients[j].name = m.name ?? "iPhone"
                clients[j].kind = m.kind ?? "iphone"
                send(Message(type: "backupReady"), to: clients[j])
                return
            }
            // A device reconnecting replaces its old connection.
            for old in clients where old.deviceID == deviceID && old.id != id && !old.backup {
                old.conn?.cancel()
                clients.removeAll { $0.id == old.id }
            }
            guard let j = clients.firstIndex(where: { $0.id == id }) else { return }
            clients[j].authed = true
            clients[j].backup = false
            clients[j].wantsBackup = m.seq == 1
            clients[j].name = m.name ?? "iPhone"
            clients[j].kind = m.kind ?? "iphone"
            clients[j].deviceID = deviceID
            // Tell the device how to reach this Mac from afar (Tailscale), so
            // nobody has to type the address in.
            tailscale = Self.localIPs().first(where: Self.isTailscale)
            var welcome = Message(type: "welcome", token: token, name: macName, state: session.snapshot, devices: devices)
            welcome.hosts = [tailscale, magicDNS].compactMap { $0 }
            send(welcome, to: clients[j])
            devicesChanged()
        case "command":
            guard clients[i].authed, let command = m.command else { return }
            if let seq = m.seq {
                let key = clients[i].deviceID
                if seenSeqs[key, default: []].contains(seq) { return }
                seenSeqs[key, default: []].append(seq)
                if seenSeqs[key]!.count > 64 { seenSeqs[key]!.removeFirst(32) }
            }
            if command.action == "device", !devices.contains(where: { $0.id == command.text }) { return }
            if command.action == "surprise" { onSurprise?(); return }
            session.perform(command)
        case "playlist":
            // Edit one of your playlists (text = playlist ID): add `ids`, remove
            // `removeIDs`, rename to `name`. With no ID, or an ID that doesn't
            // exist yet, it makes a new playlist.
            guard clients[i].authed else { return }
            let source = m.source ?? clients[i].name
            let ids = m.ids ?? []
            if let id = m.text, library.userPlaylists.contains(where: { $0.id == id }) {
                if let name = m.name { library.renamePlaylist(id, to: name, source: source) }
                if !ids.isEmpty { library.add(ids, toPlaylist: id, source: source) }
                if let gone = m.removeIDs, !gone.isEmpty { library.remove(gone, fromPlaylist: id, source: source) }
            } else {
                let given = m.text.flatMap { $0.hasPrefix("my-") ? $0 : nil }
                library.createPlaylist(named: m.name ?? "New Playlist", with: ids, id: given, source: source)
            }
        case "taste":
            guard clients[i].authed, let text = m.text else { return }
            onTaste?(Data(text.utf8))
            if let data = tasteData?() { send(Message(type: "taste", text: String(decoding: data, as: UTF8.self)), to: clients[i]) }
        case "revert":
            guard clients[i].authed, let n = m.text.flatMap(Int.init) else { return }
            library.revert(n, source: clients[i].name)
        case "reorderPlaylists":
            guard clients[i].authed, let ids = m.ids else { return }
            library.setOrder(ids)
        case "deletePlaylist":
            guard clients[i].authed, let id = m.text else { return }
            library.deletePlaylist(id, source: m.source ?? clients[i].name)
        case "exportPlaylist":
            guard clients[i].authed, let id = m.text else { return }
            onExport?(id)
        case "fetch":
            guard clients[i].authed, let peer = clients[i].peer else { return }
            serveNearby(m, to: peer, client: clients[i])
        default:
            break
        }
    }

    /// Over the nearby link there's no HTTP, so files travel as Multipeer resources.
    private func serveNearby(_ m: Message, to peer: MCPeerID, client: Client) {
        switch m.text {
        case "catalog":
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("musiplex-catalog-\(UUID().uuidString).json")
            guard (try? catalogData.write(to: file)) != nil else { return }
            nearby.sendFile(file, name: "catalog", to: peer) { try? FileManager.default.removeItem(at: file) }
        case "art":
            for id in m.ids ?? [] {
                let file = library.artDir.appendingPathComponent("\(id).jpg")
                if FileManager.default.fileExists(atPath: file.path) {
                    nearby.sendFile(file, name: "art|\(id)", to: peer, done: nil)
                } else {
                    send(Message(type: "noArt", ids: [id]), to: client)
                }
            }
        case "file":
            for id in m.ids ?? [] {
                if let url = library.url(for: id) {
                    nearby.sendFile(url, name: "file|\(id)", to: peer, done: nil)
                } else {
                    send(Message(type: "noFile", ids: [id]), to: client)
                }
            }
        default:
            break
        }
    }

    private func drop(_ id: UUID) {
        guard let client = clients.first(where: { $0.id == id }) else { return }
        clients.removeAll { $0.id == id }
        // The main link went away: its standby (Bluetooth) link takes over at once.
        if client.authed, !client.backup, let j = clients.firstIndex(where: { $0.deviceID == client.deviceID && $0.backup }) {
            clients[j].backup = false
            send(Message(type: "promoted", state: session.snapshot, devices: devices), to: clients[j])
        }
        if client.authed, !client.backup { devicesChanged() }
        // If that device was the speaker, pause rather than suddenly blasting the Mac.
        let active = session.state.activeDevice
        if active != "mac", !phones.contains(where: { $0.deviceID == active }) {
            session.perform(Command(action: "pause"))
            session.perform(Command(action: "device", text: "mac"))
        }
    }

    private func devicesChanged() {
        updateTicker()
        // Advertise over Bluetooth only while it's useful: nobody is on Wi‑Fi,
        // or a device asked for a Bluetooth standby link. Otherwise Bluetooth /
        // peer-to-peer radios stay quiet (less Wi‑Fi interference, no stutter).
        let wifiPhones = phones.filter { !$0.nearby }
        nearby.setAdvertising(wifiPhones.isEmpty || clients.contains { $0.wantsBackup || $0.backup })
        let message = Message(type: "devices", devices: devices)
        phones.forEach { send(message, to: $0) }
    }

    private func send(_ message: Message, to client: Client) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        if let peer = client.peer {
            nearby.send(data, to: peer)
        } else if let conn = client.conn {
            let meta = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "message", metadata: [meta])
            conn.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
        }
    }

    /// Lightweight position heartbeat; only runs while a device is connected.
    private func updateTicker() {
        if phones.isEmpty {
            ticker?.invalidate()
            ticker = nil
        } else if ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.session.state.isPlaying else { return }
                    let tick = Message(type: "tick", position: self.session.core.position, isPlaying: true)
                    self.phones.forEach { self.send(tick, to: $0) }
                }
            }
            ticker?.tolerance = 0.5
        }
    }

    /// This Mac's MagicDNS name (e.g. my-mac.tail1234.ts.net), if Tailscale's CLI is around.
    nonisolated static func tailscaleName() -> String? {
        let candidates = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale"]
        guard let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = ["status", "--json", "--peers=false"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let me = json["Self"] as? [String: Any], let name = me["DNSName"] as? String, !name.isEmpty else { return nil }
        return name.hasSuffix(".") ? String(name.dropLast()) : name
    }

    static func localIPs() -> [String] {
        var out: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var cursor = list
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(cString: host))
            }
        }
        return out
    }
}

/// MultipeerConnectivity advertiser: lets devices connect over Bluetooth and
/// peer-to-peer Wi‑Fi with no router or internet. Pairing still needs the PIN.
final class NearbyHost: NSObject, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, @unchecked Sendable {
    private let peerID: MCPeerID
    private let session: MCSession
    private var advertiser: MCNearbyServiceAdvertiser?

    @MainActor var onConnect: ((MCPeerID) -> Void)?
    @MainActor var onDisconnect: ((MCPeerID) -> Void)?
    @MainActor var onData: ((Data, MCPeerID) -> Void)?
    @MainActor var onError: (() -> Void)?

    init(name: String) {
        peerID = MCPeerID(displayName: name)
        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        session.delegate = self
    }

    private var advertising = false

    func start() {
        guard advertiser == nil else { return }
        let advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: ["app": "musiplex"], serviceType: Net.nearbyService)
        advertiser.delegate = self
        self.advertiser = advertiser
        setAdvertising(true)
    }

    func setAdvertising(_ on: Bool) {
        guard let advertiser, on != advertising else { return }
        advertising = on
        if on { advertiser.startAdvertisingPeer() } else { advertiser.stopAdvertisingPeer() }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        // Usually macOS's Local Network permission (reported as NSNetServices -72008).
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onError?() } }
    }

    func send(_ data: Data, to peer: MCPeerID) {
        try? session.send(data, toPeers: [peer], with: .reliable)
    }

    func sendFile(_ url: URL, name: String, to peer: MCPeerID, done: (@Sendable () -> Void)?) {
        session.sendResource(at: url, withName: name, toPeer: peer) { _ in done?() }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, session)
    }

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                switch state {
                case .connected: self.onConnect?(peerID)
                case .notConnected: self.onDisconnect?(peerID)
                default: break
                }
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onData?(data, peerID) } }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
