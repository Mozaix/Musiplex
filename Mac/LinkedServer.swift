import Foundation
import Observation

/// Another Musiplex server (e.g. the Linux laptop) whose Floaters are copied to
/// this Mac. You pair once with its address and PIN; after that this Mac
/// checks every minute and downloads any new Floaters into
/// Documents/Songs/Floaters (one way: laptop → Mac). Files are only fetched
/// once, so moving or deleting them here doesn't bring them back.
@MainActor @Observable
final class LinkedServer {
    private(set) var name = UserDefaults.standard.string(forKey: "linkedName")
    private(set) var hosts = UserDefaults.standard.stringArray(forKey: "linkedHosts") ?? []
    private(set) var status = ""
    private(set) var lastCheck: Date?
    private(set) var pulled = 0

    var isLinked: Bool { token != nil && !hosts.isEmpty }

    @ObservationIgnored private var token = UserDefaults.standard.string(forKey: "linkedToken")
    @ObservationIgnored private var fetched = Set(UserDefaults.standard.stringArray(forKey: "linkedFetched") ?? [])
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var busy = false
    @ObservationIgnored private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        return URLSession(configuration: c)
    }()

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.check() }
        }
        timer?.tolerance = 10
        Task { await check() }
    }

    /// Pairs with a server using the PIN it shows.
    func link(address: String, pin: String) async {
        let host = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, let url = URL(string: "http://\(host):\(Net.httpPort)/pair?pin=\(pin.filter(\.isNumber))") else { return }
        status = "Pairing…"
        guard let (data, response) = try? await session.data(from: url) else {
            status = "Couldn't reach \(host). Is the server running and on the same network or Tailscale?"
            return
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String else {
            status = "That PIN didn't work."
            return
        }
        self.token = token
        name = json["name"] as? String ?? host
        var all = [host] + ((json["hosts"] as? [String]) ?? [])
        all = all.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        hosts = all
        let d = UserDefaults.standard
        d.set(token, forKey: "linkedToken"); d.set(name, forKey: "linkedName"); d.set(hosts, forKey: "linkedHosts")
        status = "Linked."
        start()
        await check()
    }

    func unlink() {
        token = nil; name = nil; hosts = []; status = ""
        for key in ["linkedToken", "linkedName", "linkedHosts"] { UserDefaults.standard.removeObject(forKey: key) }
    }

    /// Lists the server's Floaters and downloads the new ones.
    func check() async {
        guard let token, !hosts.isEmpty, !busy else { return }
        busy = true
        defer { busy = false; lastCheck = Date() }
        for host in hosts {
            guard let url = URL(string: "http://\(host):\(Net.httpPort)/floaters?t=\(token)"),
                  let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
            let new = items.compactMap { $0["name"] as? String }.filter { !fetched.contains($0) }
            for file in new { await download(file, from: host, token: token) }
            status = new.isEmpty ? "Up to date" : "Copied \(new.count) new song\(new.count == 1 ? "" : "s")"
            return
        }
        status = "\(name ?? "Server") isn't reachable right now."
    }

    private func download(_ file: String, from host: String, token: String) async {
        var comps = URLComponents(string: "http://\(host):\(Net.httpPort)/floater")!
        comps.queryItems = [URLQueryItem(name: "t", value: token), URLQueryItem(name: "name", value: file)]
        guard let url = comps.url, let (temp, response) = try? await session.download(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return }
        let folder = LibraryStore.floatersFolder
        var target = folder.appendingPathComponent(file)
        if FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(target.deletingPathExtension().lastPathComponent) (laptop).\(target.pathExtension)")
        }
        guard (try? FileManager.default.moveItem(at: temp, to: target)) != nil else { return }
        fetched.insert(file)
        UserDefaults.standard.set(Array(fetched), forKey: "linkedFetched")
        pulled += 1
    }
}
