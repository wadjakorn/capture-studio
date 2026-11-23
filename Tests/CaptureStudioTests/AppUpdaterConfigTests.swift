import Foundation
import Testing
@testable import CaptureStudio

/// Sparkle must stay inert unless running from a .app with a feed + key, so
/// `swift run` / tests never hit the network or show a misconfiguration alert.
@Suite struct AppUpdaterConfigTests {
    private func makeBundle(ext: String, info: [String: Any]) throws -> Bundle {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("Test.\(ext)")
        let contents = root.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var plist = info
        plist["CFBundleIdentifier"] = "test.\(UUID().uuidString)"
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return try #require(Bundle(url: root))
    }

    private let full: [String: Any] = [
        "SUFeedURL": "https://example.com/appcast.xml",
        "SUPublicEDKey": "abc=",
    ]

    @Test func configuredAppBundle() throws {
        #expect(AppUpdater.isConfigured(try makeBundle(ext: "app", info: full)))
    }

    @Test func notAnAppBundle() throws {
        #expect(!AppUpdater.isConfigured(try makeBundle(ext: "bundle", info: full)))
    }

    @Test func missingFeedOrKey() throws {
        #expect(!AppUpdater.isConfigured(try makeBundle(ext: "app", info: ["SUPublicEDKey": "abc="])))
        #expect(!AppUpdater.isConfigured(try makeBundle(ext: "app", info: ["SUFeedURL": "https://x"])))
        #expect(!AppUpdater.isConfigured(try makeBundle(ext: "app", info: ["SUFeedURL": "", "SUPublicEDKey": "abc="])))
    }
}
