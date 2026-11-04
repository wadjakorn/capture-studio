import Foundation
import Testing
@testable import CaptureStudio

@Test func idPrefixes() {
    #expect(PhoneDeviceID.camera("abc") == "phone:abc")
    #expect(PhoneDeviceID.mic("abc") == "phone-mic:abc")
    #expect(PhoneDeviceID.phoneID(fromCamera: "phone:abc") == "abc")
    #expect(PhoneDeviceID.phoneID(fromCamera: "phone-mic:abc") == nil)
    #expect(PhoneDeviceID.phoneID(fromMic: "phone:abc") == nil)
    #expect(PhoneDeviceID.phoneID(fromMic: "phone-mic:abc") == "abc")
}
