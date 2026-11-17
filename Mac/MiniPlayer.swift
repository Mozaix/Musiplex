import AppKit
import SwiftUI

/// The small floating player: artwork, controls, and the queue on a side panel.
/// Opened from the player bar (it hides the big window); the expand button
/// brings the big window back.
struct MiniPlayerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var showQueue = false
    @State private var tint = Color(red: 0.32, green: 0.26, blue: 0.6)

    var body: some View {
        let session = model.session
        let state = session.state
        let track = model.currentTrack
        HStack(spacing: 0) {
            VStack(spacing: 14) {
                ArtworkView(id: track?.id, radius: 14)
                    .frame(width: 236, height: 236)
                    .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
                    .padding(.top, 30)

                VStack(spacing: 3) {
                    Text(track?.title ?? "Nothing playing").font(.system(size: 16, weight: .bold)).lineLimit(1)
                    Text(track?.artist ?? "Pick a song in Musiplex").font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                }
                .frame(maxWidth: .infinity)

                ScrubBar(duration: track?.duration ?? 0, position: { session.livePosition },
                         onSeek: { model.send("seek", value: $0) }, playing: state.isPlaying)

                HStack(spacing: 0) {
                    small(state.shuffle ? "shuffle" : "shuffle", active: state.shuffle) { model.send("shuffle") }
                    Spacer()
                    big("backward.fill") { model.send("prev") }
                    Spacer()
                    Button { model.send("toggle") } label: {
                        Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 20, weight: .bold)).foregroundStyle(.black)
                            .frame(width: 50, height: 50).background(.white, in: Circle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    big("forward.fill") { model.send("next") }
                    Spacer()
                    small(state.repeatMode == .one ? "repeat.1" : "repeat", active: state.repeatMode != .off) { model.send("repeat") }
                }

                HStack {
                    small("arrow.up.left.and.arrow.down.right", active: false, help: "Open the full Musiplex window") {
                        model.showFullWindow(openWindow)
                    }
                    Spacer()
                    small("list.bullet", active: showQueue, help: showQueue ? "Hide the queue" : "Show the queue") {
                        withAnimation(.spring(duration: 0.3)) { showQueue.toggle() }
                    }
                }
                .padding(.bottom, 14)
            }
            .padding(.horizontal, 18)
            .frame(width: 272)

            if showQueue {
                QueuePanel()
                    .padding(.vertical, 8).padding(.trailing, 8)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(height: 520)
        .foregroundStyle(.white)
        .background {
            ZStack {
                Theme.bg
                LinearGradient(colors: [tint.opacity(0.7), Theme.bg], startPoint: .top, endPoint: .bottom)
            }
            .ignoresSafeArea()
        }
        .background(FloatingWindow())
        .task(id: state.currentID) {
            let color = await ArtCache.shared.tint(state.currentID)
            withAnimation(.easeInOut(duration: 0.6)) { tint = color }
        }
    }

    private func small(_ name: String, active: Bool, help: String = "", action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? .white : .white.opacity(0.6))
                .frame(width: 32, height: 32)
                .background(active ? Color.white.opacity(0.18) : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func big(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 20, weight: .semibold))
                .frame(width: 40, height: 40).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Keeps the mini player above other windows, on every Space.
private struct FloatingWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.level = .floating
            window.collectionBehavior.insert(.canJoinAllSpaces)
            window.isMovableByWindowBackground = true
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
