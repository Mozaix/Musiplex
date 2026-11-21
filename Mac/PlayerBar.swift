import SwiftUI

struct PlayerBar: View {
    @Environment(AppModel.self) private var model
    @State private var showDevices = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let session = model.session
        let state = session.state
        let track = model.currentTrack
        HStack(spacing: 16) {
            // Now playing
            // Click the song to see the queue.
            Button { withAnimation(.easeOut(duration: 0.2)) { model.showQueue.toggle() } } label: {
                HStack(spacing: 12) {
                    ArtworkView(id: track?.id, radius: 6).frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track?.title ?? "Nothing playing").font(.callout.weight(.semibold)).lineLimit(1)
                        Text(track?.artist ?? "Pick a song to start").font(.caption).foregroundStyle(Theme.dim).lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show the queue")
            .frame(maxWidth: .infinity, alignment: .leading)

            // Transport
            VStack(spacing: 4) {
                HStack(spacing: 22) {
                    icon("shuffle", active: state.shuffle) { model.send("shuffle") }
                    icon("backward.fill") { model.send("prev") }
                    Button { model.send("toggle") } label: {
                        Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 36, height: 36)
                            .background(.white, in: Circle())
                    }
                    .buttonStyle(.plain)
                    icon("forward.fill") { model.send("next") }
                    icon(state.repeatMode == .one ? "repeat.1" : "repeat", active: state.repeatMode != .off) {
                        model.send("repeat")
                    }
                }
                ScrubBar(duration: track?.duration ?? 0, position: { session.livePosition },
                         onSeek: { model.send("seek", value: $0) }, playing: state.isPlaying)
            }
            .frame(maxWidth: 560)
            .layoutPriority(1)

            // Extras
            HStack(spacing: 14) {
                icon("list.bullet", active: model.showQueue) {
                    withAnimation(.easeOut(duration: 0.2)) { model.showQueue.toggle() }
                }
                icon("pip.enter") { model.showMiniPlayer(openWindow) }
                    .help("Mini player: hide this window and show a small floating player")
                Button { showDevices.toggle() } label: {
                    Image(systemName: state.activeDevice == "mac" ? "hifispeaker.and.homepod" : "iphone.radiowaves.left.and.right")
                        .foregroundStyle(model.server.listeners.isEmpty ? Theme.dim : Theme.accent)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showDevices, arrowEdge: .top) { devicePicker }
                Image(systemName: state.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(Theme.dim).frame(width: 20)
                Slider(value: Binding(get: { state.volume }, set: { model.send("volume", value: $0) }))
                    .controlSize(.small)
                    .tint(.white)
                    .frame(width: 100)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: 88)
        .overlay(alignment: .top) {
            if state.activeDevice != "mac" {
                Text("Playing on \(model.server.name(of: state.activeDevice)) · this Mac is mirroring, muted")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(Theme.gradient, in: Capsule())
                    .foregroundStyle(.black)
                    .offset(y: -10)
            }
        }
    }

    private func icon(_ name: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(active ? Theme.accent : Theme.dim)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var devicePicker: some View {
        let active = model.session.state.activeDevice
        return VStack(alignment: .leading, spacing: 6) {
            Text("Listen on").font(.headline).padding(.bottom, 4)
            deviceRow("This Mac", "laptopcomputer", selected: active == "mac") { model.send("device", text: "mac") }
            ForEach(model.server.listeners) { phone in
                deviceRow(phone.name, phone.info.symbol, selected: active == phone.deviceID) {
                    model.send("device", text: phone.deviceID)
                }
            }
            if model.server.listeners.isEmpty {
                Text("No iPhone or iPad connected").font(.caption).foregroundStyle(Theme.dim)
            }
        }
        .padding(16)
        .frame(width: 240, alignment: .leading)
    }

    private func deviceRow(_ name: String, _ symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 22)
                Text(name).lineLimit(1)
                Spacer()
                if selected { Image(systemName: "speaker.wave.2.fill").font(.caption) }
            }
            .foregroundStyle(selected ? Theme.accent : .white)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
