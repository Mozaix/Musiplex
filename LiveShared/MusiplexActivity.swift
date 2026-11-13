import ActivityKit
import AppIntents
import Foundation

/// Live Activity payload shared by the app and its widget extension.
struct MusiplexAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var artist: String
        var isPlaying: Bool
        var duration: Double
        /// Playhead at `asOf`; the widget extrapolates from there on its own.
        var position: Double
        var asOf: Date
        /// The device that's audible (the others mirror, muted).
        var deviceName: String
        var deviceSymbol: String
        /// Tiny JPEG thumbnail (kept well under the 4 KB activity limit).
        var art: Data?

        var start: Date { asOf.addingTimeInterval(-position) }
        var end: Date { start.addingTimeInterval(max(duration, 1)) }
    }
}

/// Set by the app; the intents below run in the app's process and call it.
enum LiveControl {
    @MainActor static var handler: ((String) -> Void)?
}

struct TransportIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Control Playback"
    static var isDiscoverable = false

    @Parameter(title: "Action") var action: String

    init() {}
    init(_ action: String) { self.action = action }

    func perform() async throws -> some IntentResult {
        let action = action
        await MainActor.run { LiveControl.handler?(action) }
        return .result()
    }
}
