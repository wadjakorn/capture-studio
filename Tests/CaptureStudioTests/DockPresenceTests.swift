import AppKit
import Testing
@testable import CaptureStudio

@Suite struct DockPresenceTests {
    @Test @MainActor func firstRetainGoesRegularLastReleaseGoesAccessory() {
        var applied: [NSApplication.ActivationPolicy] = []
        let dp = DockPresence(apply: { applied.append($0) })
        dp.retain(); dp.retain(); dp.release(); dp.release(); dp.release()
        #expect(applied == [.regular, .accessory])
    }

    @Test @MainActor func extraReleaseDoesNotGoNegative() {
        var applied: [NSApplication.ActivationPolicy] = []
        let dp = DockPresence(apply: { applied.append($0) })
        dp.release()
        dp.retain()
        #expect(applied == [.regular])
    }
}
