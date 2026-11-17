import AppKit
import IOKit.pwr_mgt
import Observation

/// Keeps this Mac reachable from far away:
/// - watches Tailscale and, if it's switched off, turns it back on
/// - stops the Mac from going to sleep while Musiplex is running
@MainActor @Observable
final class RemoteAccess {
    enum Status: Equatable { case connected, off, turningOn, notInstalled }

    private(set) var status = Status.off
    private(set) var tailscaleIP: String?
    private(set) var lastError: String?

    /// Turn Tailscale back on whenever it's off.
    var keepTailscaleOn = UserDefaults.standard.object(forKey: "keepTailscaleOn") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(keepTailscaleOn, forKey: "keepTailscaleOn")
            check()
        }
    }

    /// Don't let the Mac fall asleep (on its own) while Musiplex runs.
    var keepAwake = UserDefaults.standard.object(forKey: "keepAwake") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(keepAwake, forKey: "keepAwake")
            applyKeepAwake()
        }
    }

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var assertion: IOPMAssertionID = 0
    @ObservationIgnored private var lastAttempt = Date.distantPast

    static let appURL = URL(fileURLWithPath: "/Applications/Tailscale.app")
    static let cli = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"

    func start() {
        applyKeepAwake()
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer?.tolerance = 5
        // Re-check right after waking up or changing networks.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    func check() {
        let ip = Server.localIPs().first(where: Server.isTailscale)
        tailscaleIP = ip
        if ip != nil {
            status = .connected
            lastError = nil
            return
        }
        guard FileManager.default.fileExists(atPath: Self.appURL.path) else {
            status = .notInstalled
            return
        }
        if status != .turningOn { status = .off }
        if keepTailscaleOn, Date().timeIntervalSince(lastAttempt) > 60 { turnOn() }
    }

    /// Opens Tailscale if needed and asks it to connect.
    func turnOn() {
        guard FileManager.default.fileExists(atPath: Self.appURL.path) else { return }
        lastAttempt = Date()
        status = .turningOn
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: "io.tailscale.ipn.macsys").isEmpty
            || !NSRunningApplication.runningApplications(withBundleIdentifier: "io.tailscale.ipn.macos").isEmpty
        Task {
            if !running {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                _ = try? await NSWorkspace.shared.openApplication(at: Self.appURL, configuration: config)
                try? await Task.sleep(for: .seconds(5))
            }
            let error = await Task.detached { Self.run(["up"]) }.value
            try? await Task.sleep(for: .seconds(3))
            lastError = error
            if Server.localIPs().contains(where: Server.isTailscale) {
                status = .connected
                lastError = nil
            } else {
                status = .off
            }
            check()
        }
    }

    /// Runs the Tailscale command line tool; returns its error output, if any.
    nonisolated private static func run(_ args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: cli)
        task.arguments = args
        let err = Pipe()
        task.standardError = err
        task.standardOutput = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return "Couldn't start Tailscale." }
        let data = err.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return task.terminationStatus == 0 ? nil : (text.isEmpty ? "Tailscale didn't connect." : text)
    }

    private func applyKeepAwake() {
        if keepAwake, assertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "Musiplex is serving music to your devices" as CFString, &assertion)
        } else if !keepAwake, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }
}
