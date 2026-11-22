import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

private let accent = Color(red: 0.64, green: 0.54, blue: 1.0)
private let accent2 = Color(red: 1.0, green: 0.43, blue: 0.64)
private let brand = LinearGradient(colors: [accent, accent2], startPoint: .topLeading, endPoint: .bottomTrailing)

@main
struct MusiplexLiveBundle: WidgetBundle {
    var body: some Widget {
        MusiplexLiveActivity()
        MusiplexPlayWidget()
    }
}

struct MusiplexLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MusiplexAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.78))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Art(data: state.art, size: 52, radius: 10).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    DeviceBadge(state: state).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(state.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(state.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        Progress(state: state)
                        Controls(state: state)
                    }
                    .padding(.horizontal, 6)
                }
            } compactLeading: {
                Art(data: state.art, size: 24, radius: 6)
            } compactTrailing: {
                Image(systemName: state.isPlaying ? "waveform" : "pause.fill")
                    .symbolEffect(.variableColor.iterative, isActive: state.isPlaying)
                    .foregroundStyle(brand)
            } minimal: {
                Image(systemName: state.isPlaying ? "waveform" : "pause.fill").foregroundStyle(brand)
            }
            .keylineTint(accent)
        }
    }
}

private struct LockScreenView: View {
    let state: MusiplexAttributes.ContentState

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Art(data: state.art, size: 54, radius: 10)
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.title).font(.headline).lineLimit(1)
                    Text(state.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                DeviceBadge(state: state)
            }
            Progress(state: state)
            Controls(state: state)
        }
        .padding(16)
        .foregroundStyle(.white)
    }
}

private struct Art: View {
    let data: Data?
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    brand
                    Image(systemName: "music.note").font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

private struct DeviceBadge: View {
    let state: MusiplexAttributes.ContentState

    var body: some View {
        Label(state.deviceName, systemImage: state.deviceSymbol)
            .lineLimit(1)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(accent.opacity(0.25), in: Capsule())
            .foregroundStyle(accent)
    }
}

private struct Progress: View {
    let state: MusiplexAttributes.ContentState

    var body: some View {
        HStack(spacing: 8) {
            if state.isPlaying {
                Text(timerInterval: state.start...state.end, countsDown: false)
                    .frame(width: 42, alignment: .leading)
                ProgressView(timerInterval: state.start...state.end, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                    .tint(accent)
            } else {
                Text(clock(state.position)).frame(width: 42, alignment: .leading)
                ProgressView(value: min(state.position, state.duration), total: max(state.duration, 1)).tint(accent)
            }
            Text(clock(state.duration)).frame(width: 42, alignment: .trailing)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private func clock(_ t: Double) -> String {
        let s = Int(max(t, 0))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct Controls: View {
    let state: MusiplexAttributes.ContentState

    var body: some View {
        HStack(spacing: 36) {
            Button(intent: TransportIntent("prev")) { Image(systemName: "backward.fill") }
            Button(intent: TransportIntent("toggle")) {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill").font(.title2)
            }
            Button(intent: TransportIntent("next")) { Image(systemName: "forward.fill") }
        }
        .buttonStyle(.plain)
        .font(.title3)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
    }
}


// MARK: Home Screen / Lock Screen widget: start the music without opening the app

struct PlayEntry: TimelineEntry { let date: Date }

struct PlayProvider: TimelineProvider {
    func placeholder(in context: Context) -> PlayEntry { PlayEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (PlayEntry) -> Void) { completion(PlayEntry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<PlayEntry>) -> Void) {
        completion(Timeline(entries: [PlayEntry(date: .now)], policy: .never))
    }
}

struct MusiplexPlayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MusiplexPlay", provider: PlayProvider()) { _ in
            PlayWidgetView()
        }
        .configurationDisplayName("Play Music")
        .description("Start Musiplex on this phone: songs picked for you, or the album you were on.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

struct PlayWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            Button(intent: StartPlaybackIntent("surprise")) {
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "play.fill").font(.title2)
                }
            }
            .buttonStyle(.plain)
            .containerBackground(.clear, for: .widget)
        case .accessoryRectangular:
            Button(intent: StartPlaybackIntent("surprise")) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                    VStack(alignment: .leading) {
                        Text("Musiplex").font(.headline)
                        Text("Play something").font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .containerBackground(.clear, for: .widget)
        case .systemMedium:
            HStack(spacing: 10) {
                bigButton("Play Something", "sparkles", "surprise")
                bigButton("Continue", "play.fill", "last")
            }
            .containerBackground(for: .widget) { background }
        default:
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "music.note").font(.headline).foregroundStyle(brand)
                    Text("Musiplex").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.8))
                }
                Spacer(minLength: 0)
                bigButton("Play Something", "sparkles", "surprise")
            }
            .containerBackground(for: .widget) { background }
        }
    }

    private var background: some View {
        LinearGradient(colors: [Color(red: 0.11, green: 0.10, blue: 0.16), .black], startPoint: .top, endPoint: .bottom)
    }

    private func bigButton(_ title: String, _ symbol: String, _ mode: String) -> some View {
        Button(intent: StartPlaybackIntent(mode)) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.title2.weight(.bold))
                Text(title).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(brand, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
