import AppKit

/// Relaunches the app so macOS applies a freshly granted Screen Recording
/// permission (it only takes effect for new processes).
enum AppRelauncher {
    /// The path travels as `$1`, never interpolated into the script, so quotes
    /// or spaces in it can't break or inject into the shell command.
    static func shellArguments(pid: Int32, bundlePath: String) -> [String] {
        let script = "while /bin/kill -0 \"$0\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$1\""
        return ["-c", script, String(pid), bundlePath]
    }

    /// Quitting mid-take loses it (`tearDownForQuit` does not finalize a
    /// recording), so only relaunch when nothing is in flight.
    static func isSafe(state: RecordingSession.State) -> Bool {
        switch state {
        case .idle, .failed: return true
        default: return false
        }
    }

    @MainActor
    static func relaunch() {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            Log.app.info("Relaunch skipped: not running from a .app bundle")
            return
        }
        if let session = RecordingSession.shared, !isSafe(state: session.state) {
            Log.app.info("Relaunch skipped: a recording session is active")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = shellArguments(pid: ProcessInfo.processInfo.processIdentifier,
                                           bundlePath: Bundle.main.bundlePath)
        do {
            try process.run()
        } catch {
            Log.app.error("Relaunch failed to start helper: \(error.localizedDescription)")
            return
        }
        NSApp.terminate(nil)
    }
}
