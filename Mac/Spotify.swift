import AppKit
import CryptoKit
import Foundation
import Network
import Observation
import Security

/// Optional: makes Spotify playlists of new songs in your genres.
///
/// Spotify only lets an app do this through a developer app of your own
/// (free at developer.spotify.com, needs Premium, up to 5 users). You paste its
/// Client ID once and sign in in your browser; Musiplex keeps a sign-in key in
/// the Keychain. What's sent to Spotify: genre searches and the playlists made.
@MainActor @Observable
final class SpotifyLink {
    static let port: UInt16 = 43821
    static let redirect = "http://127.0.0.1:43821/callback"
    private static let scopes = "playlist-modify-private playlist-modify-public"

    var clientID = UserDefaults.standard.string(forKey: "spotifyClientID") ?? "" {
        didSet { UserDefaults.standard.set(clientID.trimmingCharacters(in: .whitespaces), forKey: "spotifyClientID") }
    }
    private(set) var connected = Keychain.read("spotify-refresh") != nil
    private(set) var status = ""
    /// Genre being worked on right now.
    private(set) var working: String?
    /// Genre → result line ("Added 25 songs to …").
    private(set) var results: [String: String] = [:]

    @ObservationIgnored private var access: (token: String, until: Date)?
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var verifier = ""
    @ObservationIgnored private var state = ""
    /// Genre → the Spotify playlist made for it, and the songs already in it.
    @ObservationIgnored private var made: [String: Made] = {
        guard let data = UserDefaults.standard.data(forKey: "spotifyPlaylists") else { return [:] }
        return (try? JSONDecoder().decode([String: Made].self, from: data)) ?? [:]
    }()

    struct Made: Codable { var id: String; var url: String; var uris: [String] }

    func playlistURL(for genre: String) -> URL? { made[genre].flatMap { URL(string: $0.url) } }

    // MARK: Sign in (PKCE, browser, loopback redirect)

    func connect() {
        let id = clientID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { status = "Paste your Client ID first."; return }
        verifier = Self.random(64)
        state = Self.random(16)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        guard startListener() else { return }
        var comps = URLComponents(string: "https://accounts.spotify.com/authorize")!
        comps.queryItems = [
            .init(name: "client_id", value: id), .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirect), .init(name: "scope", value: Self.scopes),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "code_challenge", value: challenge),
            .init(name: "state", value: state),
        ]
        status = "Finish signing in in your browser…"
        NSWorkspace.shared.open(comps.url!)
    }

    func disconnect() {
        Keychain.delete("spotify-refresh")
        access = nil
        connected = false
        status = ""
    }

    private func startListener() -> Bool {
        listener?.cancel()
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params) else {
            status = "Couldn't listen on port \(Self.port) for the sign-in."
            return false
        }
        l.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .main)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, _, _ in
                let line = data.flatMap { String(data: $0, encoding: .utf8) }?.split(separator: "\r\n").first.map(String.init) ?? ""
                let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                let query = URLComponents(string: "http://x\(path)")?.queryItems ?? []
                let ok = query.contains { $0.name == "code" }
                let page = ok ? "Signed in to Spotify. You can close this tab and go back to Musiplex."
                              : "Spotify sign-in didn't finish. You can close this tab and try again in Musiplex."
                let body = "<html><body style=\"font:16px -apple-system;padding:40px\">\(page)</body></html>"
                let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                conn.send(content: Data(reply.utf8), completion: .contentProcessed { _ in conn.cancel() })
                guard path.hasPrefix("/callback") else { return }
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.listener?.cancel()
                    self.listener = nil
                    let value = { (name: String) in query.first { $0.name == name }?.value }
                    guard value("state") == self.state, let code = value("code") else {
                        self.status = value("error") == "access_denied" ? "Sign-in was cancelled." : "Sign-in didn't work. Check the Client ID and the redirect URI."
                        return
                    }
                    Task { await self.exchange(code) }
                }
            }
        }
        l.start(queue: .main)
        listener = l
        return true
    }

    private func exchange(_ code: String) async {
        let form = ["grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirect,
                    "client_id": clientID.trimmingCharacters(in: .whitespaces), "code_verifier": verifier]
        if await tokenRequest(form) {
            connected = true
            status = "Connected to Spotify."
        } else {
            status = "Spotify didn't accept the sign-in. Check the Client ID and the redirect URI."
        }
    }

    private func tokenRequest(_ form: [String: String]) async -> Bool {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var comps = URLComponents()
        comps.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((comps.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String else { return false }
        let life = json["expires_in"] as? Double ?? 3600
        access = (token, Date().addingTimeInterval(life - 60))
        if let refresh = json["refresh_token"] as? String { Keychain.save("spotify-refresh", refresh) }
        return true
    }

    private func token() async -> String? {
        if let access, access.until > Date() { return access.token }
        guard let refresh = Keychain.read("spotify-refresh") else { connected = false; return nil }
        let ok = await tokenRequest(["grant_type": "refresh_token", "refresh_token": refresh,
                                     "client_id": clientID.trimmingCharacters(in: .whitespaces)])
        if !ok { connected = false; status = "Spotify signed you out. Connect again." }
        return ok ? access?.token : nil
    }

    // MARK: Genre playlists

    /// Finds songs in this genre on Spotify that aren't in your library, and adds
    /// them to a playlist of their own ("Musiplex · Genre"), made the first time.
    func makePlaylist(genre: String, searchTerms: [String], have: Set<String>, count: Int = 30) async {
        guard working == nil else { return }
        working = genre
        defer { working = nil }
        guard let token = await token() else { results[genre] = "Connect to Spotify first."; return }

        var previous = made[genre]
        let already = Set(previous?.uris ?? [])
        var picked: [String] = []
        var seenKeys = have
        var perArtist: [String: Int] = [:]
        search: for term in searchTerms {
            for offset in stride(from: 0, to: 100, by: 10) {
                var comps = URLComponents(string: "https://api.spotify.com/v1/search")!
                comps.queryItems = [.init(name: "q", value: "genre:\"\(term)\""), .init(name: "type", value: "track"),
                                    .init(name: "limit", value: "10"), .init(name: "offset", value: "\(offset)")]
                guard let json = await call(comps.url!, token: token),
                      let items = (json["tracks"] as? [String: Any])?["items"] as? [[String: Any]], !items.isEmpty else { break }
                for item in items {
                    guard let uri = item["uri"] as? String, let title = item["name"] as? String,
                          let artist = ((item["artists"] as? [[String: Any]])?.first?["name"]) as? String else { continue }
                    let key = songKey(title: title, artist: artist)
                    guard !already.contains(uri), seenKeys.insert(key).inserted,
                          perArtist[artist.lowercased(), default: 0] < 2 else { continue }
                    perArtist[artist.lowercased(), default: 0] += 1
                    picked.append(uri)
                    if picked.count >= count { break search }
                }
            }
        }
        guard !picked.isEmpty else { results[genre] = "Spotify found nothing new for \(genre)."; return }

        if previous == nil {
            let body: [String: Any] = ["name": "Musiplex · \(genre)", "public": false,
                                       "description": "New \(genre) songs like the ones you play, picked by Musiplex."]
            guard let json = await call(URL(string: "https://api.spotify.com/v1/me/playlists")!, token: token, method: "POST", body: body),
                  let id = json["id"] as? String else { results[genre] = "Spotify wouldn't create the playlist."; return }
            let url = ((json["external_urls"] as? [String: Any])?["spotify"] as? String) ?? "https://open.spotify.com/playlist/\(id)"
            previous = Made(id: id, url: url, uris: [])
        }
        guard var target = previous else { return }
        let added = await call(URL(string: "https://api.spotify.com/v1/playlists/\(target.id)/items")!, token: token,
                               method: "POST", body: ["uris": picked]) != nil
        guard added else {
            made[genre] = target.uris.isEmpty ? nil : target
            results[genre] = "Spotify wouldn't add the songs."
            return
        }
        target.uris += picked
        made[genre] = target
        if let data = try? JSONEncoder().encode(made) { UserDefaults.standard.set(data, forKey: "spotifyPlaylists") }
        results[genre] = "Added \(picked.count) new songs to “Musiplex · \(genre)” on Spotify."
    }

    private func call(_ url: URL, token: String, method: String = "GET", body: [String: Any]? = nil) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let code = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func random(_ n: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<n).map { _ in chars.randomElement()! })
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// A tiny Keychain wrapper (generic passwords for this app).
enum Keychain {
    private static let service = "Musiplex"

    static func save(_ account: String, _ value: String) {
        delete(account)
        SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                    kSecValueData: Data(value.utf8)] as CFDictionary, nil)
    }

    static func read(_ account: String) -> String? {
        var out: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
                                          kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account] as CFDictionary)
    }
}
