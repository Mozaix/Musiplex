import AppKit
import SwiftUI

/// Settings: playlist version history, remote access (Tailscale) and power.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Settings").font(.system(size: 26, weight: .bold))
            RemoteAccessCard()
            VersionHistoryCard(history: model.library.history)
        }
    }
}

/// Playlist versions, newest first. Click one to see exactly what changed.
struct VersionHistoryCard: View {
    let history: [PlaylistVersion]
    @State private var open: Set<Int> = []

    var body: some View {
        SettingsCard(title: "Playlist Versions", symbol: "clock.arrow.circlepath") {
            if history.isEmpty {
                Text("Every change to your playlists — from this Mac, your iPhone, your iPad or Apple Music — shows up here as a new version.")
                    .font(.callout).foregroundStyle(Theme.dim)
            } else {
                VStack(spacing: 0) {
                    ForEach(history) { version in
                        VersionRow(version: version, open: open.contains(version.number)) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if open.contains(version.number) { open.remove(version.number) } else { open.insert(version.number) }
                            }
                        }
                        if version.number != history.last?.number { Divider().overlay(Color.white.opacity(0.06)) }
                    }
                }
            }
        }
    }
}

private struct VersionRow: View {
    @Environment(AppModel.self) private var model
    let version: PlaylistVersion
    let open: Bool
    let toggle: () -> Void
    @State private var confirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: toggle) {
                HStack(spacing: 12) {
                    Text(version.label)
                        .font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit()
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Theme.accent.opacity(0.2), in: Capsule())
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(version.summary).font(.callout.weight(.semibold)).lineLimit(1)
                        HStack(spacing: 5) {
                            Image(systemName: icon(version.source)).font(.system(size: 10))
                            Text("\(version.source) · \(version.date.formatted(date: .abbreviated, time: .shortened))")
                        }
                        .font(.caption).foregroundStyle(Theme.dim)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0)).foregroundStyle(Theme.dim)
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(version.changes.enumerated()), id: \.offset) { _, change in
                        ChangeDetail(change: change)
                    }
                }
                .padding(.leading, 56)
                .transition(.opacity)
                Button { confirm = true } label: {
                    Label("Revert this version", systemImage: "arrow.uturn.backward")
                        .font(.callout.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.accent)
                .padding(.leading, 56).padding(.bottom, 12)
                .confirmationDialog("Revert version \(version.label)?", isPresented: $confirm) {
                    Button("Revert") {
                        if model.library.revert(version.number) {
                            model.show("Reverted \(version.label)")
                        } else {
                            model.show("Nothing to revert: \(version.label) is already undone.")
                        }
                    }
                } message: {
                    Text("Undoes exactly what changed in \(version.label). Your other edits stay. The undo is saved as a new version, so you can revert it too.")
                }
            }
        }
    }

    private func icon(_ source: String) -> String {
        if source.hasPrefix("Apple Music") { return "applelogo" }
        if source == "This Mac" { return "laptopcomputer" }
        if source.localizedCaseInsensitiveContains("ipad") { return "ipad" }
        return "iphone"
    }
}

private struct ChangeDetail: View {
    let change: PlaylistChange

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(color).frame(width: 14)
                Text(headline).font(.callout.weight(.semibold))
            }
            ForEach(Array(change.songs.prefix(60).enumerated()), id: \.offset) { _, song in
                HStack(spacing: 6) {
                    Text(change.kind == .removed || change.kind == .deleted ? "−" : "+")
                        .font(.caption.weight(.bold).monospaced()).foregroundStyle(color).frame(width: 14)
                    Text(song).font(.caption).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                }
            }
            if change.songs.count > 60 {
                Text("and \(change.songs.count - 60) more").font(.caption).foregroundStyle(Theme.dim).padding(.leading, 20)
            }
        }
    }

    private var headline: String {
        switch change.kind {
        case .created: "Created “\(change.playlist)”"
        case .renamed: "Renamed “\(change.detail ?? "")” to “\(change.playlist)”"
        case .deleted: "Deleted “\(change.playlist)”"
        case .added: "Added \(change.songs.count) to “\(change.playlist)”"
        case .removed: "Removed \(change.songs.count) from “\(change.playlist)”"
        }
    }

    private var symbol: String {
        switch change.kind {
        case .created: "plus.rectangle.on.rectangle"
        case .renamed: "pencil"
        case .deleted: "trash"
        case .added: "plus.circle.fill"
        case .removed: "minus.circle.fill"
        }
    }

    private var color: Color {
        switch change.kind {
        case .removed, .deleted: .red
        case .renamed: .orange
        default: .green
        }
    }
}

/// Tailscale status plus the switches that keep this Mac reachable.
struct RemoteAccessCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var remote = model.remote
        SettingsCard(title: "Listen From Anywhere", symbol: "globe") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Circle().fill(dotColor).frame(width: 9, height: 9)
                    Text(statusText).font(.callout.weight(.semibold))
                    Spacer()
                    if let ip = remote.tailscaleIP {
                        Text(ip).font(.callout.monospacedDigit()).textSelection(.enabled).foregroundStyle(Theme.dim)
                    } else if remote.status == .off {
                        Button("Turn On Tailscale") { remote.turnOn() }
                    } else if remote.status == .notInstalled {
                        Button("Get Tailscale") { NSWorkspace.shared.open(URL(string: "https://tailscale.com/download/mac")!) }
                    }
                }
                if let error = remote.lastError, remote.status != .connected {
                    Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Turn Tailscale back on if it switches off", isOn: $remote.keepTailscaleOn)
                Toggle("Keep this Mac awake while Musiplex is open", isOn: $remote.keepAwake)
                Text("Closing the lid of a MacBook still puts it to sleep unless it's plugged in with an external display. To serve music with the lid closed, run “sudo pmset -a disablesleep 1” in Terminal once (undo with 0).")
                    .font(.caption).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                Divider().overlay(Color.white.opacity(0.06))
                HStack {
                    Text("Pairing PIN").foregroundStyle(Theme.dim)
                    Spacer()
                    Text(model.server.pin).monospacedDigit().textSelection(.enabled)
                }
                .font(.callout)
            }
            .toggleStyle(.switch)
        }
    }

    private var statusText: String {
        switch model.remote.status {
        case .connected: "Tailscale is on — your devices can reach this Mac from anywhere"
        case .turningOn: "Turning Tailscale on…"
        case .off: "Tailscale is off — devices can only connect at home"
        case .notInstalled: "Tailscale isn't installed"
        }
    }

    private var dotColor: Color {
        switch model.remote.status {
        case .connected: .green
        case .turningOn: .yellow
        default: .orange
        }
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol).font(.headline)
            content
        }
        .padding(18)
        .frame(maxWidth: 760, alignment: .leading)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
