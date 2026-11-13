import Foundation
import Observation
import UIKit

/// Lets background downloads finish while the app is suspended.
final class PhoneAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        BackgroundEvents.handler = completionHandler
    }
}

enum BackgroundEvents {
    nonisolated(unsafe) static var handler: (() -> Void)?
}

/// Songs pulled from the Mac onto this device. Files live in the app's
/// Documents folder, so they also show up in Files → On My iPhone → Musiplex.
///
/// Speed: while the app is running, songs come down over a normal session,
/// several at a time at full Wi‑Fi speed. iOS's background download service
/// is much slower (it throttles and spaces out transfers), so it's only used
/// for whatever is left when iOS is about to suspend the app — and anything
/// it hasn't started yet is pulled back into the fast lane when you return.
@MainActor @Observable
final class DownloadStore: NSObject, URLSessionDownloadDelegate {
    private(set) var tracks: [Track] = []
    /// In-flight or queued downloads: track ID → fraction done.
    private(set) var progress: [String: Double] = [:]

    /// Current transfer rate in bytes per second (updated about once a second).
    private(set) var speed: Double = 0
    @ObservationIgnored private var windowBytes: Int64 = 0
    @ObservationIgnored private var windowStart = Date()

    /// Songs downloading at once in the fast lane.
    private let parallel = 6

    @ObservationIgnored private var files: [String: String] = [:]
    @ObservationIgnored private var byID: [String: Track] = [:]
    /// Waiting for a fast-lane slot.
    @ObservationIgnored private var pending: [(track: Track, url: URL)] = []
    /// The task currently responsible for each song (fast or background).
    @ObservationIgnored private var tasks: [String: URLSessionDownloadTask] = [:]
    @ObservationIgnored private var retries: [String: Int] = [:]
    /// True once iOS asked us to wrap up: new work goes to the background service.
    @ObservationIgnored private var handedOff = false
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// Identifiers of tasks running in the background service.
    @ObservationIgnored private var slowTasks = Set<ObjectIdentifier>()

    @ObservationIgnored private lazy var fast: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = parallel
        config.timeoutIntervalForRequest = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    @ObservationIgnored private lazy var slow: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.musiplex.downloads")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.httpMaximumConnectionsPerHost = parallel
        config.timeoutIntervalForRequest = 60
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    private struct Entry: Codable {
        var track: Track
        var file: String
    }

    private let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private let indexURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("downloads.json")

    override init() {
        super.init()
        try? FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL), let entries = try? JSONDecoder().decode([Entry].self, from: data) {
            for entry in entries where FileManager.default.fileExists(atPath: docs.appendingPathComponent(entry.file).path) {
                files[entry.track.id] = entry.file
                byID[entry.track.id] = entry.track
            }
            refresh()
        }
        // Pick up background downloads from a previous launch; ones that
        // haven't started yet move to the fast lane.
        slow.getAllTasks { all in
            Task { @MainActor in
                for case let task as URLSessionDownloadTask in all where task.state == .running || task.state == .suspended {
                    guard let track = Self.track(of: task) else { continue }
                    if self.has(track.id) { task.cancel(); continue }
                    self.progress[track.id] = self.progress[track.id] ?? 0
                    self.tasks[track.id] = task
                    self.slowTasks.insert(ObjectIdentifier(task))
                }
                self.reclaimUnstarted()
            }
        }
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.enteredBackground() }
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.enteredForeground() }
        }
    }

    func has(_ id: String) -> Bool { files[id] != nil }
    func track(_ id: String) -> Track? { byID[id] }
    func localURL(_ id: String) -> URL? { files[id].map { docs.appendingPathComponent($0) } }
    func isBusy(_ id: String) -> Bool { progress[id] != nil }

    var totalBytes: Int64 { tracks.reduce(0) { $0 + $1.size } }

    /// All downloaded songs' IDs.
    var ids: [String] { Array(files.keys) }

    func download(_ track: Track, from url: URL) {
        guard !has(track.id), progress[track.id] == nil else { return }
        progress[track.id] = 0
        if handedOff {
            start(track, url, on: slow)
        } else {
            pending.append((track, url))
            pump()
        }
    }

    /// Keeps the fast lane full.
    private func pump() {
        guard !handedOff else { return }
        var running = tasks.values.filter { $0.state == .running && !isSlow($0) }.count
        while running < parallel, !pending.isEmpty {
            let next = pending.removeFirst()
            guard progress[next.track.id] != nil, !has(next.track.id) else { continue }
            start(next.track, next.url, on: fast)
            running += 1
        }
    }

    private func start(_ track: Track, _ url: URL, on session: URLSession) {
        var request = URLRequest(url: url)
        request.networkServiceType = .responsiveData
        let task = session.downloadTask(with: request)
        task.taskDescription = (try? JSONEncoder().encode(track)).map { String(decoding: $0, as: UTF8.self) }
        task.priority = URLSessionTask.highPriority
        tasks[track.id] = task
        if session === slow { slowTasks.insert(ObjectIdentifier(task)) }
        task.resume()
    }


    // MARK: Foreground / background

    private func enteredBackground() {
        guard progress.isEmpty == false else { return }
        // Keep the fast lane going as long as iOS lets us (indefinitely while
        // music plays); hand off only when time runs out.
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "musiplex.downloads") { [weak self] in
            MainActor.assumeIsolated { self?.handOff() }
        }
    }

    private func enteredForeground() {
        endBackgroundTask()
        guard handedOff else { return }
        handedOff = false
        reclaimUnstarted()
    }

    /// Moves everything to iOS's background download service.
    private func handOff() {
        handedOff = true
        let queued = pending
        pending = []
        for (id, task) in tasks where !isSlow(task) {
            guard let track = Self.track(of: task), let url = task.originalRequest?.url else { continue }
            tasks[id] = nil
            task.cancel()
            start(track, url, on: slow)
        }
        for item in queued where progress[item.track.id] != nil {
            start(item.track, item.url, on: slow)
        }
        endBackgroundTask()
    }

    /// Background downloads that haven't received anything yet go back to the fast lane.
    private func reclaimUnstarted() {
        for (id, task) in tasks where isSlow(task) && task.countOfBytesReceived == 0 {
            guard let track = Self.track(of: task), let url = task.originalRequest?.url else { continue }
            tasks[id] = nil
            slowTasks.remove(ObjectIdentifier(task))
            task.cancel()
            pending.append((track, url))
        }
        pump()
    }

    private func isSlow(_ task: URLSessionTask) -> Bool { slowTasks.contains(ObjectIdentifier(task)) }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // Used by the nearby (Bluetooth) link, which delivers files itself.
    func markQueued(_ id: String) { if progress[id] == nil { progress[id] = 0 } }
    func setProgress(_ id: String, _ value: Double) { if progress[id] != nil { progress[id] = value } }
    func cancel(_ id: String) { progress[id] = nil }

    func cancelAll() {
        pending = []
        let running = tasks.values
        tasks = [:]
        slowTasks = []
        running.forEach { $0.cancel() }
        slow.getAllTasks { all in all.forEach { $0.cancel() } }
        progress = [:]
        endBackgroundTask()
    }

    /// Takes ownership of a finished file and files it under Documents.
    func adopt(_ track: Track, file: URL) {
        progress[track.id] = nil
        let clean = "\(track.artist) - \(track.title)"
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\n")).joined(separator: " ")
        var name = "\(clean.prefix(120)).\(track.ext)"
        if FileManager.default.fileExists(atPath: docs.appendingPathComponent(name).path) {
            name = "\(clean.prefix(120)) [\(track.id.prefix(6))].\(track.ext)"
        }
        let target = docs.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: target)
        guard (try? FileManager.default.moveItem(at: file, to: target)) != nil else { return }
        files[track.id] = name
        byID[track.id] = track
        scheduleSave()
    }

    func remove(_ id: String) {
        removeQuietly(id)
        scheduleSave()
    }

    /// Deletes several songs with one save.
    func remove(_ ids: [String]) {
        ids.forEach(removeQuietly)
        scheduleSave()
    }

    private func removeQuietly(_ id: String) {
        if let url = localURL(id) { try? FileManager.default.removeItem(at: url) }
        files[id] = nil
        byID[id] = nil
    }

    /// Deletes every downloaded song from this device (and stops downloads in progress).
    func removeAll() {
        cancelAll()
        for name in files.values { try? FileManager.default.removeItem(at: docs.appendingPathComponent(name)) }
        files = [:]
        byID = [:]
        scheduleSave()
    }

    // A big batch finishes many files a second: re-sort the list and write
    // the index at most a few times a second instead of after every song.
    @ObservationIgnored private var saveQueued = false

    private func scheduleSave() {
        guard !saveQueued else { return }
        saveQueued = true
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            saveQueued = false
            refresh()
            save()
        }
    }

    private func refresh() {
        tracks = byID.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func save() {
        let entries = byID.values.compactMap { t in files[t.id].map { Entry(track: t, file: $0) } }
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: indexURL, options: .atomic) }
    }

    private nonisolated static func track(of task: URLSessionTask) -> Track? {
        task.taskDescription.flatMap { try? JSONDecoder().decode(Track.self, from: Data($0.utf8)) }
    }

    // MARK: URLSessionDownloadDelegate (delivered on the main queue)

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = Self.track(of: downloadTask)?.id, totalBytesExpectedToWrite > 0 else { return }
        let value = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        MainActor.assumeIsolated {
            windowBytes += bytesWritten
            let elapsed = Date().timeIntervalSince(windowStart)
            if elapsed >= 1 {
                speed = Double(windowBytes) / elapsed
                windowBytes = 0
                windowStart = Date()
            }
            guard tasks[id] === downloadTask else { return }
            // Throttle UI updates to ~5% steps.
            if value - (progress[id] ?? 0) > 0.05 { progress[id] = value }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200, let track = Self.track(of: downloadTask) else { return }
        // The temporary file is deleted when this returns, so move it first.
        let owned = FileManager.default.temporaryDirectory.appendingPathComponent("dl-\(UUID().uuidString)")
        guard (try? FileManager.default.moveItem(at: location, to: owned)) != nil else { return }
        MainActor.assumeIsolated {
            guard tasks[track.id] === downloadTask || tasks[track.id] == nil else {
                try? FileManager.default.removeItem(at: owned)
                return
            }
            adopt(track, file: owned)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let track = Self.track(of: task) else { return }
        MainActor.assumeIsolated {
            // A task we replaced (handed off / reclaimed / cancelled) — ignore.
            guard tasks[track.id] === task else { return }
            tasks[track.id] = nil
            slowTasks.remove(ObjectIdentifier(task))
            if error != nil, !has(track.id), progress[track.id] != nil,
               let url = task.originalRequest?.url, retries[track.id, default: 0] < 3 {
                // Dropped connection: try again (up to 3 times).
                retries[track.id, default: 0] += 1
                if handedOff { start(track, url, on: slow) } else { pending.append((track, url)) }
            } else if !has(track.id) {
                progress[track.id] = nil
            }
            pump()
            if progress.isEmpty {
                speed = 0
                endBackgroundTask()
            }
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            BackgroundEvents.handler?()
            BackgroundEvents.handler = nil
        }
    }
}
