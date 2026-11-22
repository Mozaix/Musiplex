import Foundation

/// Workload's task list kept by this Mac's Musiplex, for when this Mac is the hub (no
/// linked Linux server). Same JSON and rules as the Linux/Windows server's
/// workload_tasks.py: last write wins per task; removed tasks stay 30 days (with who
/// removed them) so they can be reinstated; Toddle deadlines come in every 15 minutes.
/// Used from the HTTP server's queue, so it's locked rather than main-actor bound.
final class TaskHub: @unchecked Sendable {
    static let shared = TaskHub()

    private let lock = NSLock()
    private let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Musiplex")
    private var fileURL: URL { folder.appendingPathComponent("tasks.json") }
    private var toddleURL: URL { folder.appendingPathComponent("toddle.json") }
    private var tasks: [String: [String: Any]] = [:]
    private var toddleLinks: [String] = []
    private(set) var toddleStatus: [String: Any] = ["checked": NSNull(), "ok": NSNull(), "added": 0, "removed": 0, "found": 0, "error": ""]
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "musiplex.tasks", qos: .utility)

    private init() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: fileURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = json["tasks"] as? [[String: Any]] {
            for raw in list { if let t = Self.clean(raw) { tasks[t["id"] as! String] = t } }
        }
        if let data = try? Data(contentsOf: toddleURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            toddleLinks = json["urls"] as? [String] ?? []
        }
    }

    // MARK: Tasks

    static func clean(_ t: [String: Any]) -> [String: Any]? {
        guard let id = t["id"] as? String, !id.isEmpty else { return nil }
        let deleted = t["deleted"] as? Bool ?? false
        let urgency = ["green", "yellow", "red"].contains(t["urgency"] as? String ?? "") ? t["urgency"] as! String : "green"
        let source = t["source"] as? String == "toddle" ? "toddle" : "manual"
        let due = (t["due"] as? String).map { String($0.prefix(32)) }
        return [
            "id": String(id.prefix(200)),
            "title": String((t["title"] as? String ?? "").prefix(500)),
            "due": due ?? NSNull(),
            "urgency": urgency,
            "done": t["done"] as? Bool ?? false,
            "source": source,
            "updated": (t["updated"] as? NSNumber)?.doubleValue ?? 0,
            "deleted": deleted,
            "deletedBy": deleted ? ((t["deletedBy"] as? String).map { String($0.prefix(120)) } ?? NSNull()) as Any : NSNull(),
            "deletedAt": deleted ? ((t["deletedAt"] as? NSNumber) ?? NSNull()) as Any : NSNull(),
        ]
    }

    private static func updated(_ t: [String: Any]) -> Double { (t["updated"] as? NSNumber)?.doubleValue ?? 0 }

    /// {"tasks": [...], "now": epoch}
    func snapshot() -> Data {
        lock.lock(); defer { lock.unlock() }
        let list = tasks.values.sorted {
            (($0["due"] as? String) ?? "9999", ($0["title"] as? String ?? "").lowercased())
                < (($1["due"] as? String) ?? "9999", ($1["title"] as? String ?? "").lowercased())
        }
        return (try? JSONSerialization.data(withJSONObject: ["tasks": list, "now": Date().timeIntervalSince1970])) ?? Data("{}".utf8)
    }

    /// Last write wins, per task. A reinstated Toddle task stops following Toddle.
    func merge(_ incoming: [[String: Any]]) {
        lock.lock(); defer { lock.unlock() }
        var changed = false
        for raw in incoming {
            guard var t = Self.clean(raw) else { continue }
            let id = t["id"] as! String
            let mine = tasks[id]
            if mine == nil || Self.updated(t) > Self.updated(mine!) {
                if let mine, mine["deleted"] as? Bool == true, t["deleted"] as? Bool == false, t["source"] as? String == "toddle" {
                    t["source"] = "manual"
                }
                tasks[id] = t
                changed = true
            }
        }
        if changed { prune(); save() }
    }

    /// Toddle: new deadlines are added; changed ones updated (keeping your urgency and done
    /// mark). With `complete`, upcoming ones no longer in Toddle are removed ("by Toddle").
    @discardableResult
    func importFeed(_ items: [[String: String]], complete: Bool) -> (added: Int, removed: Int) {
        lock.lock(); defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        var added = 0, removed = 0
        var seen = Set<String>()
        for it in items {
            guard let sid = it["sourceId"], let title = it["title"], !sid.isEmpty, !title.isEmpty else { continue }
            let id = String("toddle-\(sid)".prefix(200))
            seen.insert(id)
            let due = it["due"]
            if var mine = tasks[id] {
                if mine["deleted"] as? Bool == false, (mine["title"] as? String != title || mine["due"] as? String != due) {
                    mine["title"] = title; mine["due"] = due ?? NSNull(); mine["updated"] = now
                    tasks[id] = mine
                }
            } else {
                tasks[id] = ["id": id, "title": title, "due": due ?? NSNull(), "urgency": Self.defaultUrgency(due),
                             "done": false, "source": "toddle", "updated": now, "deleted": false,
                             "deletedBy": NSNull(), "deletedAt": NSNull()]
                added += 1
            }
        }
        if complete, !seen.isEmpty {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
            let today = f.string(from: Date())
            for (id, var t) in tasks where t["source"] as? String == "toddle" && id.hasPrefix("toddle-") && !seen.contains(id)
                && t["deleted"] as? Bool == false && t["done"] as? Bool == false && ((t["due"] as? String) ?? "") >= today {
                t["deleted"] = true; t["deletedBy"] = "Toddle"; t["deletedAt"] = now; t["updated"] = now
                tasks[id] = t
                removed += 1
            }
        }
        save()
        return (added, removed)
    }

    private static func defaultUrgency(_ due: String?) -> String {
        guard let due, let d = parseDue(due) else { return "green" }
        let end = d.allDay ? Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: d.date) ?? d.date : d.date
        let days = end.timeIntervalSinceNow / 86400
        return days <= 1 ? "red" : days <= 3 ? "yellow" : "green"
    }

    /// "2026-11-28" (all day) or "2026-11-28T23:59", local time.
    private static func parseDue(_ due: String) -> (date: Date, allDay: Bool)? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current
        if due.contains("T") { f.dateFormat = "yyyy-MM-dd'T'HH:mm"; if let d = f.date(from: String(due.prefix(16))) { return (d, false) } }
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(due.prefix(10))).map { ($0, true) }
    }

    private func prune() {
        let cutoff = Date().timeIntervalSince1970 - 30 * 86400
        tasks = tasks.filter { !($0.value["deleted"] as? Bool == true && Self.updated($0.value) < cutoff) }
    }

    private func save() {
        guard let data = try? JSONSerialization.data(withJSONObject: ["tasks": Array(tasks.values)], options: [.prettyPrinted]) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: Toddle (every 15 minutes, link kept only on this Mac)

    var toddleLink: String { lock.lock(); defer { lock.unlock() }; return toddleLinks.first ?? "" }

    func setToddle(_ link: String) {
        let url = link.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        toddleLinks = url.isEmpty ? [] : [url]
        if let data = try? JSONSerialization.data(withJSONObject: ["urls": toddleLinks]) {
            try? data.write(to: toddleURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: toddleURL.path)
        }
        lock.unlock()
        checkToddle()
    }

    func startToddle() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 20, repeating: 15 * 60, leeway: .seconds(30))
        t.setEventHandler { [weak self] in self?.checkToddle() }
        t.resume()
        timer = t
    }

    func checkToddle() {
        let links = { lock.lock(); defer { lock.unlock() }; return toddleLinks }()
        guard !links.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            var items: [[String: String]] = []
            var complete = true, error = ""
            for link in links {
                guard let url = URL(string: link.replacingOccurrences(of: "webcal://", with: "https://")) else { complete = false; continue }
                var request = URLRequest(url: url, timeoutInterval: 30)
                request.setValue("Musiplex-Workload/2.4", forHTTPHeaderField: "User-Agent")
                guard let (data, response) = try? await URLSession.shared.data(for: request),
                      (response as? HTTPURLResponse)?.statusCode == 200 else {
                    complete = false; error = "Couldn't reach Toddle"; continue
                }
                let text = String(decoding: data, as: UTF8.self)
                guard text.contains("BEGIN:VCALENDAR") else { complete = false; error = "Toddle didn't send a calendar"; continue }
                items += Self.parseFeed(text)
            }
            let result = items.isEmpty ? (added: 0, removed: 0) : self.importFeed(items, complete: complete)
            self.lock.lock()
            self.toddleStatus = ["checked": Date().timeIntervalSince1970, "ok": error.isEmpty, "added": result.added,
                                 "removed": result.removed, "found": items.count, "error": error]
            self.lock.unlock()
        }
    }

    func toddleInfo() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let url = toddleLinks.first ?? ""
        return ["set": !url.isEmpty, "link": url.count > 30 ? String(url.prefix(28)) + "…" : url,
                "status": toddleStatus, "every": 900]
    }

    /// Toddle's calendar (iCal) → upcoming deadlines. Reminders inside an event are skipped.
    static func parseFeed(_ text: String, daysAhead: Double = 60) -> [[String: String]] {
        var lines: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n") {
            if let first = raw.first, first == " " || first == "\t", !lines.isEmpty { lines[lines.count - 1] += raw.dropFirst() }
            else if !raw.isEmpty { lines.append(raw) }
        }
        var events: [[String: (params: [String: String], value: String)]] = []
        var cur: [String: (params: [String: String], value: String)]?
        var nested = 0
        for line in lines {
            if line == "BEGIN:VEVENT" || line == "BEGIN:VTODO" { cur = [:]; nested = 0 }
            else if line == "END:VEVENT" || line == "END:VTODO" { if let c = cur { events.append(c) }; cur = nil }
            else if cur != nil, line.hasPrefix("BEGIN:") { nested += 1 }
            else if cur != nil, line.hasPrefix("END:") { nested = max(0, nested - 1) }
            else if cur != nil, nested == 0, let colon = line.firstIndex(of: ":") {
                let head = line[..<colon].split(separator: ";").map(String.init)
                var params: [String: String] = [:]
                for p in head.dropFirst() { let kv = p.split(separator: "=", maxSplits: 1).map(String.init); if kv.count == 2 { params[kv[0]] = kv[1] } }
                cur?[head[0].uppercased()] = (params, String(line[line.index(after: colon)...]))
            }
        }
        let now = Date(), horizon = now.addingTimeInterval(daysAhead * 86400)
        var out: [[String: String]] = []
        for ev in events {
            guard let uid = ev["UID"], let summary = ev["SUMMARY"], let raw = ev["DUE"] ?? ev["DTSTART"],
                  let when = when(raw.params, raw.value) else { continue }
            let endOfDay = when.hasTime ? when.date : Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: when.date) ?? when.date
            guard endOfDay >= now.addingTimeInterval(-86400), endOfDay <= horizon else { continue }
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current
            f.dateFormat = when.hasTime ? "yyyy-MM-dd'T'HH:mm" : "yyyy-MM-dd"
            let title = summary.value.replacingOccurrences(of: "\\n", with: " ").replacingOccurrences(of: "\\N", with: " ")
                .replacingOccurrences(of: "\\,", with: ",").replacingOccurrences(of: "\\;", with: ";")
                .replacingOccurrences(of: "\\\\", with: "\\").trimmingCharacters(in: .whitespaces)
            let sid = String(uid.value.filter { $0.isLetter || $0.isNumber || "_.@-".contains($0) }.prefix(150))
            out.append(["sourceId": sid, "title": title, "due": f.string(from: when.date)])
        }
        return out
    }

    private static func when(_ params: [String: String], _ raw: String) -> (date: Date, hasTime: Bool)? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        if params["VALUE"] == "DATE" || (value.count == 8 && value.allSatisfy(\.isNumber)) {
            f.dateFormat = "yyyyMMdd"; f.timeZone = .current
            return f.date(from: String(value.prefix(8))).map { ($0, false) }
        }
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        if value.hasSuffix("Z") { f.timeZone = TimeZone(identifier: "UTC") }
        else if let tz = params["TZID"].flatMap({ TimeZone(identifier: $0.trimmingCharacters(in: CharacterSet(charactersIn: "\""))) }) { f.timeZone = tz }
        else { f.timeZone = .current }
        return f.date(from: String(value.replacingOccurrences(of: "Z", with: "").prefix(15))).map { ($0, true) }
    }
}
