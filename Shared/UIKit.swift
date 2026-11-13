import SwiftUI
import MediaPlayer

#if os(macOS)
import AppKit
typealias PlatformImage = NSImage
extension NSImage {
    var cg: CGImage? { cgImage(forProposedRect: nil, context: nil, hints: nil) }
}
extension Image {
    init(platform: PlatformImage) { self.init(nsImage: platform) }
}
#else
import UIKit
typealias PlatformImage = UIImage
extension UIImage {
    var cg: CGImage? { cgImage }
}
extension Image {
    init(platform: PlatformImage) { self.init(uiImage: platform) }
}
#endif

enum Theme {
    static let bg = Color(red: 0.027, green: 0.027, blue: 0.043)
    static let panel = Color(red: 0.07, green: 0.07, blue: 0.092)
    static let raised = Color.white.opacity(0.07)
    static let accent = Color(red: 0.64, green: 0.54, blue: 1.0)
    static let accent2 = Color(red: 1.0, green: 0.43, blue: 0.64)
    static let dim = Color.white.opacity(0.58)
    static let gradient = LinearGradient(colors: [accent, accent2], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// In-memory artwork cache in front of a platform-specific loader.
@MainActor
final class ArtCache {
    static let shared = ArtCache()
    var loader: @Sendable (String) async -> PlatformImage? = { _ in nil }
    private let cache = NSCache<NSString, PlatformImage>()
    private var misses = Set<String>()

    init() { cache.countLimit = 400 }

    func cached(_ id: String) -> PlatformImage? { cache.object(forKey: id as NSString) }

    func image(_ id: String) async -> PlatformImage? {
        if let hit = cached(id) { return hit }
        if misses.contains(id) { return nil }
        let loader = self.loader
        guard let image = await Task.detached(operation: { await loader(id) }).value else {
            misses.insert(id)
            return nil
        }
        cache.setObject(image, forKey: id as NSString)
        return image
    }

    func resetMisses() { misses.removeAll() }

    /// Average colour of a track's artwork, used to tint backgrounds.
    func tint(_ id: String?) async -> Color {
        let fallback = Color(red: 0.32, green: 0.26, blue: 0.6)
        guard let id, let cg = await image(id)?.cg else { return fallback }
        var px = [UInt8](repeating: 0, count: 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                      bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard ok else { return fallback }
        return Color(red: Double(px[0]) / 255, green: Double(px[1]) / 255, blue: Double(px[2]) / 255)
    }
}

struct ArtworkView: View {
    let id: String?
    var radius: CGFloat = 6
    @State private var image: PlatformImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors: [Color.white.opacity(0.13), Color.white.opacity(0.05)],
                               startPoint: .top, endPoint: .bottom)
                if let image {
                    Image(platform: image).resizable().scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: max(10, geo.size.width * 0.36), weight: .medium))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        .aspectRatio(1, contentMode: .fit)
        .task(id: id) {
            guard let id else { image = nil; return }
            image = ArtCache.shared.cached(id)
            if image == nil { image = await ArtCache.shared.image(id) }
        }
    }
}

/// Seek bar that polls the playhead and lets you drag to seek.
struct ScrubBar: View {
    let duration: Double
    let position: () -> Double
    let onSeek: (Double) -> Void
    var showTimes = true
    /// When false the bar stops redrawing entirely (nothing is moving).
    var playing = true
    @State private var drag: Double?
    @State private var hover = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.5, paused: !playing)) { _ in
            let pos = drag ?? min(position(), max(duration, 0))
            let active = hover || drag != nil
            HStack(spacing: 10) {
                if showTimes {
                    Text(timeString(pos)).frame(width: 44, alignment: .trailing)
                }
                GeometryReader { geo in
                    let frac = duration > 0 ? CGFloat(min(max(pos / duration, 0), 1)) : 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.16))
                        Capsule().fill(active ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.white))
                            .frame(width: max(0, geo.size.width * frac))
                        Circle().fill(.white).frame(width: 12, height: 12)
                            .offset(x: geo.size.width * frac - 6)
                            .opacity(active ? 1 : 0)
                    }
                    .frame(height: 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            guard duration > 0 else { return }
                            drag = Double(min(max(v.location.x / max(geo.size.width, 1), 0), 1)) * duration
                        }
                        .onEnded { _ in
                            if let drag { onSeek(drag) }
                            drag = nil
                        })
                }
                .frame(height: 18)
                if showTimes {
                    Text(timeString(duration)).frame(width: 44, alignment: .leading)
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(Theme.dim)
        }
        .onHover { hover = $0 }
    }
}

/// Publishes the current track to the system (lock screen, media keys) and
/// routes system transport controls back into the session.
@MainActor
final class NowPlayingBridge {
    init(send: @escaping @MainActor (Command) -> Void) {
        let center = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ action: String) {
            command.addTarget { _ in
                Task { @MainActor in send(Command(action: action)) }
                return .success
            }
        }
        on(center.playCommand, "resume")
        on(center.pauseCommand, "pause")
        on(center.togglePlayPauseCommand, "toggle")
        on(center.nextTrackCommand, "next")
        on(center.previousTrackCommand, "prev")
        center.changePlaybackPositionCommand.addTarget { event in
            let t = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime ?? 0
            Task { @MainActor in send(Command(action: "seek", value: t)) }
            return .success
        }
    }

    func update(track: Track?, position: Double, playing: Bool) {
        let center = MPNowPlayingInfoCenter.default()
        guard let track else {
            center.nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
        ]
        if let image = ArtCache.shared.cached(track.id) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        center.nowPlayingInfo = info
        #if os(macOS)
        center.playbackState = playing ? .playing : .paused
        #endif
    }
}
