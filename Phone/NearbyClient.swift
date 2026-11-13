import Foundation
import MultipeerConnectivity

/// Finds the Mac over Bluetooth / peer-to-peer Wi‑Fi (MultipeerConnectivity)
/// for when there's no shared network. Messages are the same JSON as the
/// Wi‑Fi link; files arrive as Multipeer resources.
final class NearbyClient: NSObject, MCSessionDelegate, MCNearbyServiceBrowserDelegate, @unchecked Sendable {
    private let peerID: MCPeerID
    private let session: MCSession
    private let browser: MCNearbyServiceBrowser
    private var found: MCPeerID?
    private var mac: MCPeerID?
    private var inviting = false
    private var progressObservers: [String: NSKeyValueObservation] = [:]

    @MainActor var onFound: (() -> Void)?
    @MainActor var onConnect: (() -> Void)?
    @MainActor var onDisconnect: (() -> Void)?
    @MainActor var onData: ((Data) -> Void)?
    @MainActor var onProgress: ((String, Double) -> Void)?
    /// (resource name, local file you now own, or nil on failure)
    @MainActor var onResource: ((String, URL?) -> Void)?

    init(name: String) {
        peerID = MCPeerID(displayName: name)
        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        browser = MCNearbyServiceBrowser(peer: peerID, serviceType: Net.nearbyService)
        super.init()
        session.delegate = self
        browser.delegate = self
        browser.startBrowsingForPeers()
    }

    var hasMacNearby: Bool { found != nil }
    var isConnected: Bool { mac != nil }

    func connect() {
        guard let found, mac == nil, !inviting else { return }
        inviting = true
        browser.invitePeer(found, to: session, withContext: nil, timeout: 12)
    }

    func disconnect() {
        session.disconnect()
        mac = nil
        inviting = false
    }

    func send(_ data: Data) {
        guard let mac else { return }
        try? session.send(data, toPeers: [mac], with: .reliable)
    }

    // MARK: Browser

    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        found = peerID
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onFound?() } }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        if found == peerID { found = nil }
    }

    // MARK: Session

    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        switch state {
        case .connected:
            mac = peerID
            inviting = false
            DispatchQueue.main.async { MainActor.assumeIsolated { self.onConnect?() } }
        case .notConnected:
            let wasConnected = mac == peerID
            if wasConnected { mac = nil }
            inviting = false
            if wasConnected { DispatchQueue.main.async { MainActor.assumeIsolated { self.onDisconnect?() } } }
        default:
            break
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onData?(data) } }
    }

    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID,
                 with progress: Progress) {
        guard resourceName.hasPrefix("file|") else { return }
        var last = 0.0
        progressObservers[resourceName] = progress.observe(\.fractionCompleted) { [weak self] p, _ in
            let value = p.fractionCompleted
            guard value - last > 0.04 else { return }
            last = value
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onProgress?(resourceName, value) } }
        }
    }

    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID,
                 at localURL: URL?, withError error: Error?) {
        progressObservers[resourceName] = nil
        // The temporary file is deleted when this returns, so move it first.
        var owned: URL?
        if error == nil, let localURL {
            let target = FileManager.default.temporaryDirectory.appendingPathComponent("nearby-\(UUID().uuidString)")
            if (try? FileManager.default.moveItem(at: localURL, to: target)) != nil { owned = target }
        }
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onResource?(resourceName, owned) } }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
}
