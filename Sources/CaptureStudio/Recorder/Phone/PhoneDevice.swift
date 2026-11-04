import Foundation
import Network

struct PhoneDevice: Identifiable, Equatable {
    let id: String
    var name: String
    var protocolMajor: Int
    var endpoint: NWEndpoint
}

enum PhoneDeviceID {
    private static let cameraPrefix = "phone:"
    private static let micPrefix = "phone-mic:"

    static func camera(_ id: String) -> String { cameraPrefix + id }
    static func mic(_ id: String) -> String { micPrefix + id }

    static func phoneID(fromCamera s: String) -> String? {
        s.hasPrefix(cameraPrefix) ? String(s.dropFirst(cameraPrefix.count)) : nil
    }
    static func phoneID(fromMic s: String) -> String? {
        s.hasPrefix(micPrefix) ? String(s.dropFirst(micPrefix.count)) : nil
    }
}
