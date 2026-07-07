import SwiftUI
import Testing
@testable import CaptureStudio

@Suite struct ColorHexTests {
    @Test func roundTripsPrimaries() {
        #expect(Color(hexString: "#FF0000").hexString() == "#FF0000")
        #expect(Color(hexString: "#00FF00").hexString() == "#00FF00")
        #expect(Color(hexString: "#0000FF").hexString() == "#0000FF")
    }
    @Test func acceptsNoHashAndLowercase() {
        #expect(Color(hexString: "ffffff").hexString() == "#FFFFFF")
    }
    @Test func fallsBackToWhiteOnGarbage() {
        #expect(Color(hexString: "nope").hexString() == "#FFFFFF")
    }
}
