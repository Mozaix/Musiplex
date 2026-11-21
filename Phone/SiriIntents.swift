import AppIntents
import Foundation

// Siri: "Play something on Musiplex", "Play music on Musiplex", "Close Musiplex".
// Siri needs the app's name in the phrase (a plain "play music" always goes to
// Apple Music), so each command has a few ways to say it.

/// Surprise: songs picked for you (from the Mac when connected, otherwise from downloads).
struct PlaySomethingIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Something"
    static let description = IntentDescription("Plays songs picked for you (Surprise).")

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = PhoneModel.shared
        await model.readyForSiri()
        model.startSurprise()
        return .result()
    }
}

/// Picks up the album you were last listening to, at the song you were on.
struct PlayMusicIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Music"
    static let description = IntentDescription("Plays the album you last listened to, from the song you were on.")

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = PhoneModel.shared
        await model.readyForSiri()
        model.playLastAlbum()
        return .result()
    }
}

/// Stops all playback (on the phone and, if connected, the Mac) and closes the app.
struct CloseMusiplexIntent: AppIntent {
    static let title: LocalizedStringResource = "Close Musiplex"
    static let description = IntentDescription("Stops the music everywhere and closes Musiplex.")

    @MainActor
    func perform() async throws -> some IntentResult {
        PhoneModel.shared.stopForSiri()
        // Give the pause a moment to reach the Mac, then quit for real.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            exit(0)
        }
        return .result()
    }
}

struct MusiplexShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlaySomethingIntent(), phrases: [
            "Play something on \(.applicationName)",
            "Play something in \(.applicationName)",
            "\(.applicationName) play something",
            "Surprise me on \(.applicationName)",
        ], shortTitle: "Play Something", systemImageName: "sparkles")
        AppShortcut(intent: PlayMusicIntent(), phrases: [
            "Play music on \(.applicationName)",
            "Play music in \(.applicationName)",
            "\(.applicationName) play music",
            "Resume \(.applicationName)",
            "Play \(.applicationName)",
        ], shortTitle: "Play Music", systemImageName: "play.fill")
        AppShortcut(intent: CloseMusiplexIntent(), phrases: [
            "Close \(.applicationName)",
            "Stop \(.applicationName)",
            "Quit \(.applicationName)",
            "Close music on \(.applicationName)",
            "Stop music on \(.applicationName)",
        ], shortTitle: "Close Musiplex", systemImageName: "stop.fill")
    }
}
