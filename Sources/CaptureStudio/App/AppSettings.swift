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

    /// Record only a sub-rectangle of the display instead of the whole screen.
    static var captureAreaEnabled: Bool {
        get { defaults.bool(forKey: "captureAreaEnabled") }
        set { defaults.set(newValue, forKey: "captureAreaEnabled") }
    }

    /// Last selected capture region, in display-local points (top-left origin
    /// within the display). nil = never selected. Stored as 4 Doubles so the
    /// global hotkey can reuse it without opening the popup.
    static var captureRegion: CGRect? {
        get {
            guard defaults.object(forKey: "captureRegionW") != nil else { return nil }
            let w = defaults.double(forKey: "captureRegionW")
            let h = defaults.double(forKey: "captureRegionH")
            guard w > 0, h > 0 else { return nil }
            return CGRect(x: defaults.double(forKey: "captureRegionX"),
                          y: defaults.double(forKey: "captureRegionY"),
                          width: w, height: h)
        }
        set {
            if let r = newValue {
                defaults.set(r.origin.x, forKey: "captureRegionX")
                defaults.set(r.origin.y, forKey: "captureRegionY")
                defaults.set(r.width, forKey: "captureRegionW")
                defaults.set(r.height, forKey: "captureRegionH")
            } else {
                for k in ["captureRegionX", "captureRegionY", "captureRegionW", "captureRegionH"] {
                    defaults.removeObject(forKey: k)
                }
                captureRegionDisplayID = nil  // region cleared → its display id too
            }
        }
    }

    /// Display the saved `captureRegion` was dragged on. Area capture derives the
    /// recorded display from the region's screen, not from the Display picker.
    static var captureRegionDisplayID: CGDirectDisplayID? {
        get { (defaults.object(forKey: "captureRegionDisplayID") as? Int).map { CGDirectDisplayID($0) } }
        set { set(newValue.map { Int($0) }, forKey: "captureRegionDisplayID") }
    }

    private static func set(_ value: Any?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
