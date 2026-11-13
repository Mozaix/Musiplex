import Foundation
import WatchConnectivity

/// Keeps the Apple Watch app in step with playback and relays its button
/// presses back into the session. Only sends when something visible changes.
final class WatchBridge: NSObject, WCSessionDelegate, @unchecked Sendable {
    @MainActor var onCommand: ((Command) -> Void)?
    @MainActor private var last: [String: Any] = [:]
    @MainActor private var lastExpected: (position: Double, at: Date, playing: Bool)?

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// `context` must exclude position/asOf; those are passed separately so
    /// steady playback doesn't cause a message every update.
    @MainActor func update(_ context: [String: Any], position: Double, playing: Bool) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        // Don't gate on isPaired / isWatchAppInstalled: they flicker, and
        // updateApplicationContext simply fails harmlessly when there's no watch.
        guard session.activationState == .activated else {
            last = [:]
            return
        }
        if NSDictionary(dictionary: context).isEqual(to: last), let e = lastExpected, e.playing == playing {
            let expected = e.position + (playing ? Date().timeIntervalSince(e.at) : 0)
            if abs(expected - position) < 2 { return }
        }
        last = context
        lastExpected = (position, Date(), playing)
        var full = context
        full["position"] = position
        full["asOf"] = Date()
        try? session.updateApplicationContext(full)
        if session.isReachable { session.sendMessage(["context": full], replyHandler: nil, errorHandler: nil) }
    }

    /// Asks the app to push its current state again.
    @MainActor var onResend: (() -> Void)?

    @MainActor func resend() {
        last = [:]
        onResend?()
    }

    private func command(from message: [String: Any]) -> Command? {
        guard let action = message["action"] as? String else { return nil }
        return Command(action: action, value: message["value"] as? Double, text: message["text"] as? String)
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.resend() } }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.resend() } }
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.resend() } }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let command = command(from: message) else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onCommand?(command) } }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        replyHandler(["ok": true])
        self.session(session, didReceiveMessage: message)
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }
}
