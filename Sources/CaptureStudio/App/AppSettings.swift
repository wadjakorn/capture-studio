import Foundation
import CoreGraphics

/// Last-used device selections, persisted so the global hotkey can start a
/// recording without opening the menubar popup.
enum AppSettings {
    private static let defaults = UserDefaults.standard

    static var lastDisplayID: CGDirectDisplayID? {
        get { (defaults.object(forKey: "lastDisplayID") as? Int).map { CGDirectDisplayID($0) } }
        set { set(newValue.map { Int($0) }, forKey: "lastDisplayID") }
    }

    static var lastCameraID: String? {
        get { defaults.string(forKey: "lastCameraID") }
        set { set(newValue, forKey: "lastCameraID") }
    }

    static var lastMicID: String? {
        get { defaults.string(forKey: "lastMicID") }
        set { set(newValue, forKey: "lastMicID") }
    }

    /// Capture system audio (SCStream) alongside the screen.
    static var recordSystemAudio: Bool {
        get { defaults.object(forKey: "recordSystemAudio") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "recordSystemAudio") }
    }

    /// Countdown length before recording starts; 0 disables it.
    static var countdownSeconds: Int {
        get { defaults.object(forKey: "countdownSeconds") as? Int ?? 3 }
        set { defaults.set(newValue, forKey: "countdownSeconds") }
    }

    private static func set(_ value: Any?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
