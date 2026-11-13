import Observation
import SwiftUI
import WatchConnectivity

private let accent = Color(red: 0.64, green: 0.54, blue: 1.0)
private let accent2 = Color(red: 1.0, green: 0.43, blue: 0.64)
private let brand = LinearGradient(colors: [accent, accent2], startPoint: .topLeading, endPoint: .bottomTrailing)

@main
struct MusiplexWatchApp: App {
    @State private var model = WatchModel()

    var body: some Scene {
        WindowGroup {
            WatchRoot().environment(model)
        }
    }
}

struct WatchDevice: Identifiable, Hashable {
    var id: String
    var name: String
    var kind: String
    var symbol: String { kind == "mac" ? "laptopcomputer" : kind == "ipad" ? "ipad" : "iphone" }
}

/// Mirrors what the iPhone app sends over WatchConnectivity, and sends taps back.
@MainActor @Observable
final class WatchModel {
    var title = ""
    var artist = ""
    var trackID = ""
    var duration = 0.0
    var position = 0.0
    var asOf = Date()
    var playing = false
    var linked = false
    var macName = "Mac"
    var active = ""
    var volume = 0.8
    var shuffle = false
    var devices: [WatchDevice] = []
    var art: UIImage?
    var reachable = false

    @ObservationIgnored private let link = WatchLink()
    @ObservationIgnored private var volumeTask: Task<Void, Never>?

    init() {
        link.onContext = { [weak self] in self?.apply($0) }
        link.onReachability = { [weak self] in self?.reachable = $0 }
        link.start()
    }

    var start: Date { asOf.addingTimeInterval(-position) }
    var activeDevice: WatchDevice? { devices.first { $0.id == active } }

    private func apply(_ c: [String: Any]) {
        title = c["title"] as? String ?? ""
        artist = c["artist"] as? String ?? ""
        let id = c["id"] as? String ?? ""
        if id != trackID || art == nil { art = (c["art"] as? Data).flatMap(UIImage.init(data:)) }
        trackID = id
        duration = c["duration"] as? Double ?? 0
        position = c["position"] as? Double ?? 0
        asOf = c["asOf"] as? Date ?? Date()
        playing = c["playing"] as? Bool ?? false
        linked = c["linked"] as? Bool ?? false
        macName = c["macName"] as? String ?? "Mac"
        active = c["active"] as? String ?? ""
        volume = c["volume"] as? Double ?? volume
        shuffle = c["shuffle"] as? Bool ?? false
        devices = (c["devices"] as? [[String: String]] ?? []).compactMap { d in
            guard let id = d["id"], let name = d["name"] else { return nil }
            return WatchDevice(id: id, name: name, kind: d["kind"] ?? "iphone")
        }
    }

    func send(_ action: String, value: Double? = nil, text: String? = nil) {
        var message: [String: Any] = ["action": action]
        if let value { message["value"] = value }
        if let text { message["text"] = text }
        link.send(message)
        // Feel instant; the next update from the phone confirms it.
        switch action {
        case "toggle":
            if playing { position += Date().timeIntervalSince(asOf) }
            asOf = Date()
            playing.toggle()
        case "next", "prev":
            position = 0
            asOf = Date()
        case "device":
            if let text { active = text }
        default:
            break
        }
    }

    /// Digital Crown volume (Mac only), coalesced so the Mac isn't flooded.
    func setVolume(_ value: Double) {
        volume = value
        volumeTask?.cancel()
        volumeTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            send("volume", value: value)
        }
    }
}

final class WatchLink: NSObject, WCSessionDelegate, @unchecked Sendable {
    @MainActor var onContext: (([String: Any]) -> Void)?
    @MainActor var onReachability: ((Bool) -> Void)?

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func send(_ message: [String: Any]) {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        // Using a reply handler wakes the iPhone app if it's in the background.
        session.sendMessage(message, replyHandler: { _ in }, errorHandler: { _ in })
    }

    private func deliver(_ context: [String: Any]) {
        guard !context.isEmpty else { return }
        let box = UncheckedBox(context)
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onContext?(box.value) } }
    }

    private func reachability(_ on: Bool) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onReachability?(on) } }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        deliver(session.receivedApplicationContext)
        reachability(session.isReachable)
    }

    func sessionReachabilityDidChange(_ session: WCSession) { reachability(session.isReachable) }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        deliver(applicationContext)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if let context = message["context"] as? [String: Any] { deliver(context) }
    }
}

private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

// MARK: Views

struct WatchRoot: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        NavigationStack {
            if model.title.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "waveform").font(.system(size: 34, weight: .semibold)).foregroundStyle(brand)
                    Text("Nothing playing").font(.headline)
                    Text(model.reachable ? "Play something on your Mac or iPhone." : "Open Musiplex on your iPhone.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding()
            } else {
                NowPlaying()
            }
        }
    }
}

struct NowPlaying: View {
    @Environment(WatchModel.self) private var model
    @State private var crown = 0.8
    @State private var showDevices = false

    var body: some View {
        let onMac = model.linked && model.active == "mac"
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                artwork.frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(model.artist).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            progress

            HStack {
                button("backward.fill", size: 18) { model.send("prev") }
                Spacer()
                Button { model.send("toggle") } label: {
                    Image(systemName: model.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 22, weight: .bold)).foregroundStyle(.black)
                        .frame(width: 52, height: 52).background(.white, in: Circle())
                }
                .buttonStyle(.plain)
                Spacer()
                button("forward.fill", size: 18) { model.send("next") }
            }
            .padding(.horizontal, 4)

            Button { showDevices = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: model.activeDevice?.symbol ?? "iphone")
                    Text(model.activeDevice?.name ?? "Choose device").lineLimit(1)
                    if onMac {
                        Spacer(minLength: 2)
                        Image(systemName: "speaker.wave.2.fill").font(.system(size: 11))
                        Text("\(Int((model.volume * 100).rounded()))").monospacedDigit()
                    }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(accent)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(accent.opacity(0.18), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .background {
            ZStack {
                artwork.blur(radius: 24).opacity(0.55)
                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
            }
            .ignoresSafeArea()
        }
        .focusable(onMac)
        .digitalCrownRotation($crown, from: 0, through: 1, by: 0.02, sensitivity: .low,
                              isContinuous: false, isHapticFeedbackEnabled: true)
        .onChange(of: crown) { _, value in
            if onMac, abs(value - model.volume) > 0.005 { model.setVolume(value) }
        }
        .onChange(of: model.volume) { _, value in crown = value }
        .onAppear { crown = model.volume }
        .sheet(isPresented: $showDevices) { DevicePicker() }
    }

    @ViewBuilder private var artwork: some View {
        if let art = model.art {
            Image(uiImage: art).resizable().scaledToFill()
        } else {
            ZStack {
                brand
                Image(systemName: "music.note").foregroundStyle(.white)
            }
        }
    }

    @ViewBuilder private var progress: some View {
        let end = model.start.addingTimeInterval(max(model.duration, 1))
        if model.playing, model.start < end {
            ProgressView(timerInterval: model.start...end, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                .tint(accent)
        } else {
            ProgressView(value: min(model.position, model.duration), total: max(model.duration, 1)).tint(accent)
        }
    }

    private func button(_ name: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: size, weight: .semibold))
                .frame(width: 40, height: 40).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct DevicePicker: View {
    @Environment(WatchModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("Play on") {
                ForEach(model.devices) { device in
                    Button {
                        model.send("device", text: device.id)
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: device.symbol).frame(width: 22)
                            Text(device.name).lineLimit(1)
                            Spacer()
                            if device.id == model.active {
                                Image(systemName: "speaker.wave.2.fill").foregroundStyle(accent)
                            }
                        }
                    }
                }
            }
            Section {
                Button {
                    model.send("shuffle")
                } label: {
                    Label(model.shuffle ? "Shuffle On" : "Shuffle Off", systemImage: "shuffle")
                        .foregroundStyle(model.shuffle ? accent : .white)
                }
            }
        }
    }
}
