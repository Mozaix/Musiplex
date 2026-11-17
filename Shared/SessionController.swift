import AVFoundation
import Observation

/// Plays one song at a time, with an optional crossfade: two players take
/// turns, so the next song can fade in while the last one fades out.
@MainActor
final class PlayerCore {
    private let players = [AVPlayer(), AVPlayer()]
    private var current = 0
    private var player: AVPlayer { players[current] }
    private var endObserver: NSObjectProtocol?
    private var nearEnd: (token: Any, owner: AVPlayer)?
    private var fadeTimer: Timer?
    /// Volume the audible player should be at (0 when this device is muted).
    private var target: Float = 1
    var onEnded: (() -> Void)?
    /// Fires `crossfade` seconds before the end, so the next song can start.
    var onNearEnd: (() -> Void)?
    /// Seconds of overlap between songs (0 = no crossfade).
    var crossfade: Double = 0
    private(set) var loadedID: String?

    var position: Double {
        let t = player.currentTime().seconds
        return t.isFinite ? max(0, t) : 0
    }

    var volume: Float {
        get { target }
        set {
            target = newValue
            // While fading, the fade timer applies the new level.
            if fadeTimer == nil, player.volume != newValue { player.volume = newValue }
        }
    }

    var isBuffering: Bool { player.timeControlStatus == .waitingToPlayAtSpecifiedRate }

    /// - Parameters:
    ///   - duration: song length, used to schedule the crossfade (0 = unknown).
    ///   - fade: seconds to fade from whatever is playing into this song (0 = cut).
    func load(id: String, url: URL, at position: Double, playing: Bool, duration: Double = 0, fade: Double = 0) {
        loadedID = id
        let outgoing = player
        let crossfading = fade > 0 && playing && outgoing.currentItem != nil && outgoing.rate > 0
        stopFade(keepOutgoing: crossfading)
        if crossfading { current = 1 - current }
        let p = player

        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let nearEnd { nearEnd.owner.removeTimeObserver(nearEnd.token) }
        nearEnd = nil

        let item = AVPlayerItem(url: url)
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEnded?() }
        }
        p.replaceCurrentItem(with: item)
        if position > 0.3 { seek(position) }
        if crossfade > 0, duration > crossfade + 2 {
            let at = NSValue(time: CMTime(seconds: duration - crossfade, preferredTimescale: 600))
            let token = p.addBoundaryTimeObserver(forTimes: [at], queue: .main) { [weak self] in
                MainActor.assumeIsolated { self?.onNearEnd?() }
            }
            nearEnd = (token, p)
        }

        if crossfading {
            p.volume = 0
            p.play()
            startFade(in: p, out: outgoing, seconds: fade)
        } else {
            p.volume = target
            if playing { p.play() } else { p.pause() }
        }
    }

    /// Equal-power fade, updated 20 times a second only while a fade runs.
    private func startFade(in incoming: AVPlayer, out outgoing: AVPlayer, seconds: Double) {
        let start = Date()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let k = min(Date().timeIntervalSince(start) / seconds, 1)
                incoming.volume = self.target * Float(sin(k * .pi / 2))
                outgoing.volume = self.target * Float(cos(k * .pi / 2))
                if k >= 1 { self.stopFade(keepOutgoing: false) }
            }
        }
    }

    /// Ends any fade: the audible player goes to full level, the other stops.
    private func stopFade(keepOutgoing: Bool) {
        fadeTimer?.invalidate()
        fadeTimer = nil
        player.volume = target
        guard !keepOutgoing else { return }
        let other = players[1 - current]
        if other.currentItem != nil {
            other.pause()
            other.replaceCurrentItem(with: nil)
        }
    }

    func seek(_ t: Double) {
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setPlaying(_ on: Bool) {
        if on {
            if player.timeControlStatus == .paused { player.play() }
        } else {
            stopFade(keepOutgoing: false)
            player.pause()
        }
    }

    func unload() {
        guard loadedID != nil else { return }
        stopFade(keepOutgoing: false)
        player.replaceCurrentItem(with: nil)
        loadedID = nil
    }
}

/// Runs a playback session. In authoritative mode (the Mac, or the phone when
/// offline) it applies commands and owns the timeline. In follower mode (the
/// phone while connected) it mirrors the state it is sent.
@MainActor @Observable
final class SessionController {
    var state = SessionState()
    var isFollower = false
    let device: String

    @ObservationIgnored let core = PlayerCore()
    @ObservationIgnored var resolveURL: (String) -> URL? = { _ in nil }
    /// Song length in seconds, for scheduling crossfades.
    @ObservationIgnored var durationOf: (String) -> Double = { _ in 0 }
    @ObservationIgnored var onChange: ((SessionState) -> Void)?
    @ObservationIgnored var onApplied: (() -> Void)?
    @ObservationIgnored private var unshuffled: [String]?
    @ObservationIgnored private var anchorPos = 0.0
    @ObservationIgnored private var anchorAt = Date()
    @ObservationIgnored private var loadedAt = Date.distantPast

    init(device: String) {
        self.device = device
        core.onEnded = { [weak self] in
            guard let self, !self.isFollower else { return }
            self.perform(Command(action: "auto"))
        }
        core.onNearEnd = { [weak self] in
            guard let self, !self.isFollower, self.state.isPlaying, self.state.repeatMode != .one,
                  self.state.index + 1 < self.state.queue.count || self.state.repeatMode == .all else { return }
            // Start the next song now so the two overlap.
            self.perform(Command(action: "auto"))
        }
    }

    var isAudibleHere: Bool { state.activeDevice == device }

    /// Best current estimate of the playhead, for UI.
    var livePosition: Double {
        guard isFollower else { return core.position }
        return anchorPos + (state.isPlaying ? Date().timeIntervalSince(anchorAt) : 0)
    }

    /// State with a fresh position, for sending to followers.
    var snapshot: SessionState {
        var s = state
        s.position = core.position
        return s
    }

    // MARK: Authoritative

    func perform(_ c: Command) {
        guard !isFollower else { return }
        var seek: Double?
        state.fade = 0
        switch c.action {
        case "play":
            guard let ids = c.ids, !ids.isEmpty else { return }
            var i = min(max(c.index ?? 0, 0), ids.count - 1)
            var queue = ids
            if state.shuffle {
                unshuffled = ids
                let current = queue.remove(at: i)
                queue.shuffle()
                queue.insert(current, at: 0)
                i = 0
            } else {
                unshuffled = nil
            }
            state.queue = queue
            state.index = i
            state.isPlaying = true
            seek = 0
        case "jump":
            guard let i = c.index, state.queue.indices.contains(i) else { return }
            state.index = i
            state.isPlaying = true
            seek = 0
        case "toggle":
            guard state.currentID != nil else { return }
            state.isPlaying.toggle()
        case "pause":
            state.isPlaying = false
        case "resume":
            guard state.currentID != nil else { return }
            state.isPlaying = true
        case "next":
            advance(auto: false)
            seek = 0
        case "auto":
            advance(auto: true)
            state.fade = state.crossfade
            seek = 0
        case "crossfade":
            state.crossfade = min(max(c.value ?? 0, 0), 12)
        case "prev":
            if core.position < 3, state.index > 0 { state.index -= 1 }
            seek = 0
        case "seek":
            seek = max(0, c.value ?? 0)
        case "volume":
            state.volume = min(max(c.value ?? state.volume, 0), 1)
        case "device":
            guard let d = c.text, !d.isEmpty else { return }
            state.activeDevice = d
        case "shuffle":
            state.shuffle.toggle()
            if state.shuffle {
                unshuffled = state.queue
                if let current = state.currentID {
                    var rest = state.queue
                    rest.remove(at: state.index)
                    rest.shuffle()
                    state.queue = [current] + rest
                    state.index = 0
                }
            } else if let original = unshuffled, let current = state.currentID,
                      let i = original.firstIndex(of: current) {
                state.queue = original
                state.index = i
                unshuffled = nil
            }
        case "repeat":
            state.repeatMode = switch state.repeatMode {
            case .off: .all
            case .all: .one
            case .one: .off
            }
        case "playNext", "enqueue":
            guard let ids = c.ids, !ids.isEmpty else { return }
            if state.queue.isEmpty {
                state.queue = ids
                state.index = 0
                state.isPlaying = true
                seek = 0
            } else if c.action == "playNext" {
                state.queue.insert(contentsOf: ids, at: state.index + 1)
            } else {
                state.queue.append(contentsOf: ids)
            }
        default:
            return
        }
        apply(seek: seek)
        onChange?(snapshot)
        onApplied?()
    }

    private func advance(auto: Bool) {
        guard !state.queue.isEmpty else { return }
        if auto, state.repeatMode == .one { return }
        if state.index + 1 < state.queue.count {
            state.index += 1
        } else {
            state.index = 0
            if auto, state.repeatMode == .off { state.isPlaying = false }
        }
    }

    private func apply(seek: Double?) {
        // The Mac honours the session volume; the phone uses its hardware volume.
        core.volume = isAudibleHere ? (device == "mac" ? Float(state.volume) : 1) : 0
        core.crossfade = state.crossfade
        guard let id = state.currentID, let url = resolveURL(id) else {
            core.unload()
            return
        }
        if core.loadedID != id {
            core.load(id: id, url: url, at: seek ?? 0, playing: state.isPlaying,
                      duration: durationOf(id), fade: state.fade)
        } else {
            if let seek { core.seek(seek) }
            core.setPlaying(state.isPlaying)
        }
    }

    // MARK: Follower

    func follow(_ s: SessionState) {
        isFollower = true
        if state != s { state = s }
        sync(position: s.position)
    }

    func tick(position: Double, isPlaying: Bool) {
        guard isFollower else { return }
        if state.isPlaying != isPlaying { state.isPlaying = isPlaying }
        sync(position: position)
    }

    private func sync(position: Double) {
        anchorPos = position
        anchorAt = Date()
        core.volume = isAudibleHere ? 1 : 0
        defer { onApplied?() }
        guard let id = state.currentID, let url = resolveURL(id) else {
            core.unload()
            return
        }
        if core.loadedID != id {
            // Crossfade along with the Mac when it just moved to this song.
            let fade = position < state.fade + 1.5 ? state.fade : 0
            core.load(id: id, url: url, at: position, playing: state.isPlaying, fade: fade)
            loadedAt = Date()
        } else {
            // Muted mirrors stay tight; the device you're listening on only
            // jumps if it's well out (a small drift isn't worth an audible skip).
            let limit = isAudibleHere ? 4.0 : 2.0
            if !core.isBuffering, Date().timeIntervalSince(loadedAt) > 5, abs(core.position - position) > limit {
                core.seek(position)
            }
            core.setPlaying(state.isPlaying)
        }
    }

    /// Leave follower mode (connection lost): pause and take local control.
    func detach() {
        guard isFollower else { return }
        let position = livePosition
        isFollower = false
        state.isPlaying = false
        state.activeDevice = device
        state.position = position
        core.setPlaying(false)
        core.volume = 1
        onApplied?()
    }
}
