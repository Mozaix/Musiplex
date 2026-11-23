import Foundation
import Network


/// Minimal HTTP file server (library JSON, artwork, audio with Range support).
/// Runs on its own queue and streams files in chunks, never loading them whole.
final class HTTPServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "musiplex.http", qos: .userInitiated)
    private let lock = NSLock()
    private var listener: NWListener?
    private var paths: [String: String] = [:]
    private var library = Data("[]".utf8)
    /// Where Workload on this Mac should sync (the linked Linux server, or this Mac): set by the app.
    private var hub: [String: Any] = [:]
    /// Keys also accepted for /tasks: the linked server's, so a phone paired with it
    /// (or nearby over Bluetooth) can sync with this Mac too.
    private var taskKeys: Set<String> = []
    private let token: String
    private let artDir: URL

    init(token: String, artDir: URL) {
        self.token = token
        self.artDir = artDir
    }

    func update(paths: [String: String], library: Data) {
        lock.lock()
        self.paths = paths
        self.library = library
        lock.unlock()
    }

    func setHub(_ value: [String: Any], taskKeys keys: Set<String> = []) {
        lock.lock(); hub = value; taskKeys = keys; lock.unlock()
    }

    func acceptsTaskKey(_ key: String?) -> Bool {
        guard let key, !key.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        return key == token || taskKeys.contains(key)
    }

    func start(port: Int) throws {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.serviceClass = .responsiveData
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: UInt16(port))!)
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            conn.start(queue: self.queue)
            self.readHead(conn, Data())
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func readHead(_ conn: NWConnection, _ buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                let length = head.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.dropFirst(15).trimmingCharacters(in: .whitespaces)) } ?? 0
                guard length > 0 else { return self.handle(conn, head, Data()) }
                guard length <= 4 << 20 else { return self.respond(conn, 413, "Payload Too Large") }
                self.readBody(conn, head, Data(buffer[end.upperBound...]), length)
            } else if error != nil || done || buffer.count > 65536 {
                conn.cancel()
            } else {
                self.readHead(conn, buffer)
            }
        }
    }

    private func readBody(_ conn: NWConnection, _ head: String, _ body: Data, _ length: Int) {
        if body.count >= length { return handle(conn, head, body.prefix(length)) }
        conn.receive(minimumIncompleteLength: 1, maximumLength: length - body.count) { [weak self] data, _, done, error in
            guard let self else { return }
            var body = body
            if let data { body.append(data) }
            if error != nil || (done && body.count < length) { conn.cancel(); return }
            self.readBody(conn, head, body, length)
        }
    }

    /// This Mac only (and through its own address, so web pages can't reach it).
    private func isLocal(_ conn: NWConnection, _ lines: [String]) -> Bool {
        guard case .hostPort(let host, _) = conn.endpoint else { return false }
        let remote = "\(host)".split(separator: "%").first.map(String.init) ?? ""
        guard remote == "127.0.0.1" || remote == "::1" || remote == "::ffff:127.0.0.1" else { return false }
        let hostHeader = lines.first { $0.lowercased().hasPrefix("host:") }?.dropFirst(5).trimmingCharacters(in: .whitespaces) ?? ""
        let name = hostHeader.hasPrefix("[") ? String(hostHeader.split(separator: "]").first?.dropFirst() ?? "")
            : String(hostHeader.split(separator: ":").first ?? "")
        return ["127.0.0.1", "localhost", "::1"].contains(name)
    }

    private func json(_ conn: NWConnection, _ object: Any) {
        respond(conn, 200, "OK", type: "application/json",
                body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8))
    }

    private func handle(_ conn: NWConnection, _ head: String, _ body: Data) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count >= 2, let comps = URLComponents(string: String(parts[1])) else {
            return respond(conn, 400, "Bad Request")
        }
        let method = String(parts[0])
        guard ["GET", "HEAD", "POST"].contains(method) else { return respond(conn, 405, "Method Not Allowed") }
        var range: String?
        for line in lines.dropFirst() where line.lowercased().hasPrefix("range:") {
            range = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
        }
        let path = comps.path
        if path == "/ping" { return respond(conn, 200, "OK", body: Data("musiplex".utf8)) }

        // Workload on this Mac: where to sync (no PIN), the task list, and the Toddle link.
        if path.hasPrefix("/local/") {
            guard isLocal(conn, lines) else { return respond(conn, 403, "Forbidden") }
            let writeOK = lines.contains { $0.lowercased().replacingOccurrences(of: " ", with: "") == "x-musiplex:1" }
            switch (path, method) {
            case ("/local/workload", "GET"):
                lock.lock(); var h = hub; lock.unlock()
                if h["via"] as? String == "local" { h["toddle"] = !TaskHub.shared.toddleLink.isEmpty }
                return json(conn, h)
            case ("/local/tasks", "GET"):
                return respond(conn, 200, "OK", type: "application/json", body: TaskHub.shared.snapshot())
            case ("/local/tasks", "POST"):
                guard writeOK, let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return respond(conn, 403, "Forbidden") }
                let items = (obj["tasks"] as? [[String: Any]] ?? []).map { $0.compactMapValues { $0 as? String } }
                let r = TaskHub.shared.importFeed(items, complete: obj["complete"] as? Bool ?? false)
                return json(conn, ["added": r.added, "removed": r.removed])
            case ("/local/toddle", "GET"):
                return json(conn, TaskHub.shared.toddleInfo())
            case ("/local/toddle", "POST"):
                guard writeOK, let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return respond(conn, 403, "Forbidden") }
                TaskHub.shared.setToddle(obj["url"] as? String ?? "")
                return json(conn, TaskHub.shared.toddleInfo())
            default:
                return respond(conn, 404, "Not Found")
            }
        }
        let key = comps.queryItems?.first(where: { $0.name == "t" })?.value
        if path == "/tasks" {
            guard acceptsTaskKey(key) else { return respond(conn, 401, "Unauthorized") }
            if method == "POST" {
                guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return respond(conn, 400, "Bad Request") }
                TaskHub.shared.merge(obj["tasks"] as? [[String: Any]] ?? [])
            }
            return respond(conn, 200, "OK", type: "application/json", body: TaskHub.shared.snapshot())
        }
        guard key == token else { return respond(conn, 401, "Unauthorized") }

        if path == "/catalog" {
            lock.lock(); let body = library; lock.unlock()
            respond(conn, 200, "OK", type: "application/json", body: body)
        } else if path.hasPrefix("/art/") {
            let id = String(path.dropFirst(5)).filter { $0.isHexDigit }
            sendFile(conn, artDir.appendingPathComponent("\(id).jpg").path, type: "image/jpeg", range: nil, headOnly: method == "HEAD")
        } else if path.hasPrefix("/file/") {
            let name = String(path.dropFirst(6))
            let id = name.split(separator: ".").first.map(String.init) ?? name
            lock.lock(); let file = paths[id]; lock.unlock()
            guard let file else { return respond(conn, 404, "Not Found") }
            sendFile(conn, file, type: Self.mime((file as NSString).pathExtension), range: range, headOnly: method == "HEAD")
        } else {
            respond(conn, 404, "Not Found")
        }
    }

    private static func mime(_ ext: String) -> String {
        switch ext.lowercased() {
        case "mp3": "audio/mpeg"
        case "m4a", "aac": "audio/mp4"
        case "mp4", "m4v": "video/mp4"
        case "mov": "video/quicktime"
        case "wav": "audio/wav"
        case "aif", "aiff": "audio/aiff"
        case "flac": "audio/flac"
        default: "application/octet-stream"
        }
    }

    private func respond(_ conn: NWConnection, _ code: Int, _ reason: String,
                         type: String = "text/plain", body: Data = Data()) {
        var out = Data("HTTP/1.1 \(code) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(body)
        conn.send(content: out, contentContext: .finalMessage, isComplete: true,
                  completion: .contentProcessed { _ in conn.cancel() })
    }

    private func sendFile(_ conn: NWConnection, _ path: String, type: String, range: String?, headOnly: Bool) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              let handle = FileHandle(forReadingAtPath: path) else {
            return respond(conn, 404, "Not Found")
        }
        var start: Int64 = 0, end = size - 1, partial = false
        if let range, range.hasPrefix("bytes="), size > 0 {
            let spec = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            if spec.count == 2 {
                if spec[0].isEmpty, let suffix = Int64(spec[1]) {
                    start = max(0, size - suffix)
                } else if let s = Int64(spec[0]) {
                    start = s
                    if let e = Int64(spec[1]) { end = min(e, size - 1) }
                }
                partial = true
            }
            if start > end || start >= size {
                try? handle.close()
                return respond(conn, 416, "Range Not Satisfiable")
            }
        }
        let length = max(0, end - start + 1)
        var head = "HTTP/1.1 \(partial ? "206 Partial Content" : "200 OK")\r\nContent-Type: \(type)\r\nContent-Length: \(length)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n"
        if partial { head += "Content-Range: bytes \(start)-\(end)/\(size)\r\n" }
        head += "\r\n"
        try? handle.seek(toOffset: UInt64(start))
        conn.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] error in
            if error != nil || headOnly || length == 0 {
                try? handle.close()
                self?.finish(conn)
            } else {
                self?.pump(conn, handle, remaining: length)
            }
        })
    }

    private func pump(_ conn: NWConnection, _ handle: FileHandle, remaining: Int64) {
        let count = Int(min(remaining, 1024 * 1024))
        guard let chunk = try? handle.read(upToCount: count), !chunk.isEmpty else {
            try? handle.close()
            return finish(conn)
        }
        let left = remaining - Int64(chunk.count)
        conn.send(content: chunk, completion: .contentProcessed { [weak self] error in
            if error == nil, left > 0 {
                self?.pump(conn, handle, remaining: left)
            } else {
                try? handle.close()
                self?.finish(conn)
            }
        })
    }

    private func finish(_ conn: NWConnection) {
        conn.send(content: nil, contentContext: .finalMessage, isComplete: true,
                  completion: .contentProcessed { _ in conn.cancel() })
    }
}

