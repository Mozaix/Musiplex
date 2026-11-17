import AppKit
import SwiftUI

/// Musiplex's menu bar popup: a compact now-playing card tinted by the
/// artwork, with devices and quick actions underneath.
struct MenuBarPlayer: View {
    @Environment(AppModel.self) private var model
    @State private var tint = Color(red: 0.32, green: 0.26, blue: 0.6)

    var body: some View {
        VStack(spacing: 0) {
            NowPlayingCard(tint: tint)
            VStack(alignment: .leading, spacing: 14) {
                DeviceList()
                QuickActions()
            }
            .padding(14)
        }
        .frame(width: 300)
        .background(Theme.bg)
        // Always light-on-dark, even when macOS is in light mode (otherwise
        // un-styled text turns black on the dark background).
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .task(id: model.session.state.currentID) {
            let color = await ArtCache.shared.tint(model.session.state.currentID)
            withAnimation(.easeInOut(duration: 0.6)) { tint = color }
        }
    }
}

private struct NowPlayingCard: View {
    @Environment(AppModel.self) private var model
    let tint: Color

    var body: some View {
        let session = model.session
        let state = session.state
        let track = model.currentTrack
        VStack(spacing: 14) {
            if let track {
                HStack(spacing: 14) {
                    ArtworkView(id: track.id, radius: 10)
                        .frame(width: 72, height: 72)
                        .shadow(color: .black.opacity(0.45), radius: 10, y: 5)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title).font(.system(size: 15, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                        Text(track.artist).font(.system(size: 12)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                        HStack(spacing: 5) {
                            Image(systemName: state.activeDevice == "mac" ? "laptopcomputer" : "iphone")
                            Text(state.activeDevice == "mac" ? "This Mac" : model.server.name(of: state.activeDevice))
                                .lineLimit(1)
                        }
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.black.opacity(0.45), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                        .padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                }

                ScrubBar(duration: track.duration, position: { session.livePosition },
                         onSeek: { model.send("seek", value: $0) }, playing: state.isPlaying)

                HStack(spacing: 0) {
                    small(state.repeatMode == .one ? "repeat.1" : "repeat", active: state.repeatMode != .off) { model.send("repeat") }
                    Spacer()
                    big("backward.fill") { model.send("prev") }
                    Spacer()
                    Button { model.send("toggle") } label: {
                        Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 18, weight: .bold)).foregroundStyle(.black)
                            .frame(width: 44, height: 44).background(.white, in: Circle())
                            .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    big("forward.fill") { model.send("next") }
                    Spacer()
                    small("shuffle", active: state.shuffle) { model.send("shuffle") }
                }

                if state.activeDevice == "mac" {
                    VolumeBar(value: state.volume) { model.send("volume", value: $0) }
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "waveform")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 54, height: 54)
                        .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    Text("Nothing playing").font(.system(size: 14, weight: .bold))
                    Text("Pick something to listen to in Musiplex.")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.65))
                    Button("Open Musiplex") { openMain() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(.white, in: Capsule())
                        .foregroundStyle(.black)
                        .padding(.top, 2)
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .background {
            ZStack {
                LinearGradient(colors: [tint.opacity(0.85), tint.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)
                // Keep white text readable even on very light artwork.
                Color.black.opacity(0.28)
                LinearGradient(colors: [.clear, Theme.bg.opacity(0.9)], startPoint: .center, endPoint: .bottom)
            }
        }
    }

    private func small(_ name: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(active ? .white : .white.opacity(0.5))
                .frame(width: 28, height: 28)
                .background(active ? Color.white.opacity(0.18) : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func big(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Thin capsule volume control that matches the scrub bar.
private struct VolumeBar: View {
    let value: Double
    let onChange: (Double) -> Void
    @State private var drag: Double?

    var body: some View {
        let v = drag ?? value
        HStack(spacing: 10) {
            Image(systemName: v == 0 ? "speaker.slash.fill" : "speaker.fill")
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.6)).frame(width: 14)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                    Capsule().fill(.white).frame(width: max(4, geo.size.width * v))
                }
                .frame(height: 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let x = min(max(g.location.x / max(geo.size.width, 1), 0), 1)
                        drag = x
                        onChange(x)
                    }
                    .onEnded { _ in drag = nil })
            }
            .frame(height: 16)
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
        }
    }
}

/// Which device plays the sound.
private struct DeviceList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let active = model.session.state.activeDevice
        VStack(alignment: .leading, spacing: 6) {
            Text("PLAY ON").font(.system(size: 9, weight: .semibold, design: .monospaced)).kerning(1.5)
                .foregroundStyle(.white.opacity(0.6))
            ForEach(model.server.devices) { device in
                let on = device.id == active
                Button { model.send("device", text: device.id) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: device.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 26, height: 26)
                            .background(on ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Color.white.opacity(0.08)), in: Circle())
                            .foregroundStyle(on ? .black : .white)
                        Text(device.id == "mac" ? "This Mac" : device.name)
                            .font(.system(size: 12, weight: on ? .semibold : .medium))
                            .foregroundStyle(on ? .white : .white.opacity(0.85))
                            .lineLimit(1)
                        Spacer()
                        if on {
                            Image(systemName: "waveform").font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .padding(6)
                    .background(on ? Color.white.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Bottom row of round icon buttons.
private struct QuickActions: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            action("rectangle.topthird.inset.filled", "Open the notch") { model.notch.open() }
            action("gearshape.fill", "Notch settings") { model.notch.open(tab: .settings) }
            action(model.notchEnabled ? "eye.fill" : "eye.slash.fill",
                   model.notchEnabled ? "Hide the notch" : "Show the notch", on: model.notchEnabled) {
                model.notchEnabled.toggle()
            }
            Spacer()
            action("macwindow", "Open Musiplex") { openMain() }
            action("power", "Quit Musiplex") { NSApp.terminate(nil) }
        }
    }

    private func action(_ symbol: String, _ help: String, on: Bool = false, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(on ? AnyShapeStyle(Theme.accent.opacity(0.35)) : AnyShapeStyle(Color.white.opacity(0.08)), in: Circle())
                .foregroundStyle(.white)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

@MainActor private func openMain() {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
}

/// The icon itself: a waveform while music plays.
struct MenuBarIcon: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Image(systemName: model.session.state.isPlaying ? "waveform" : "waveform.circle")
    }
}
