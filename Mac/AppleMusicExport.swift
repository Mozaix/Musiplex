import Foundation

/// Copies a Musiplex playlist into the Music app. Songs already in your Apple
/// Music library are linked by their Music ID (no duplicate copies); songs that
/// aren't get imported from their file. A playlist with the same name is
/// refreshed rather than duplicated. macOS asks once for permission to control Music.
enum AppleMusicExport {
    struct Song: Sendable {
        var path: String
        var musicID: String?
    }

    enum Result: Sendable {
        case done(Int)
        case failed(String)
    }

    static func send(name: String, songs: [Song]) async -> Result {
        func quote(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        var script = """
        tell application "Music"
            if exists user playlist \(quote(name)) then
                set p to user playlist \(quote(name))
                delete every track of p
            else
                set p to make new user playlist with properties {name:\(quote(name))}
            end if
            set added to 0

        """
        for song in songs {
            let file = "add (POSIX file \(quote(song.path))) to p"
            if let id = song.musicID {
                script += """
                    try
                        duplicate (first track of library playlist 1 whose persistent ID is \(quote(id))) to p
                        set added to added + 1
                    on error
                        try
                            \(file)
                            set added to added + 1
                        end try
                    end try

                """
            } else {
                script += """
                    try
                        \(file)
                        set added to added + 1
                    end try

                """
            }
        }
        script += """
            return added
        end tell
        """

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-"]
                let input = Pipe(), output = Pipe(), errors = Pipe()
                process.standardInput = input
                process.standardOutput = output
                process.standardError = errors
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: .failed(error.localizedDescription))
                    return
                }
                input.fileHandleForWriting.write(Data(script.utf8))
                try? input.fileHandleForWriting.close()
                let out = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let err = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    continuation.resume(returning: .done(Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? songs.count))
                } else if err.contains("-1743") {
                    continuation.resume(returning: .failed("Musiplex isn't allowed to control Music. Turn it on in System Settings → Privacy & Security → Automation."))
                } else {
                    continuation.resume(returning: .failed(err.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
        }
    }
}
