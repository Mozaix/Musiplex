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

    func start(port: Int) throws {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = true
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
                self.handle(conn, String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            } else if error != nil || done || buffer.count > 65536 {
                conn.cancel()
            } else {
                self.readHead(conn, buffer)
            }
        }
    }

    private func handle(_ conn: NWConnection, _ head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count >= 2, let comps = URLComponents(string: String(parts[1])) else {
            return respond(conn, 400, "Bad Request")
        }
        let method = String(parts[0])
        guard method == "GET" || method == "HEAD" else { return respond(conn, 405, "Method Not Allowed") }
        var range: String?
        for line in lines.dropFirst() where line.lowercased().hasPrefix("range:") {
            range = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
        }
        let path = comps.path
        if path == "/ping" { return respond(conn, 200, "OK", body: Data("musiplex".utf8)) }
        guard comps.queryItems?.first(where: { $0.name == "t" })?.value == token else {
            return respond(conn, 401, "Unauthorized")
        }

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

