import AppIntents
import Foundation

/// Set by the app; the Home Screen widget's buttons run in the app's process
/// (audio-playback intents do) and call it.
enum WidgetPlay {
    @MainActor static var handler: ((String) async -> Void)?
}

/// A widget button: "surprise" (Play Something) or "last" (the album you were on).
struct StartPlaybackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Start Musiplex"
    static var isDiscoverable = false

    @Parameter(title: "Mode") var mode: String

    init() {}
    init(_ mode: String) { self.mode = mode }

    @MainActor
    func perform() async throws -> some IntentResult {
        await WidgetPlay.handler?(mode)
        return .result()
    }
}
