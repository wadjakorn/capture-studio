import Testing
@testable import CaptureStudio

@Test func phoneRowsShowFindHintWhenIdle() {
    let g = DeviceDiscovery.cameraRows(local: [], phones: [], browsing: false)
    #expect(g.first { $0.kind == .phoneWiFi }?.rows.first?.id == "phone-find")
}
@Test func versionMismatchDisabled() {
    let d = PhoneDevice(id: "A", name: "Galaxy", protocolMajor: 2, endpoint: .hostPort(host: "1.2.3.4", port: 1))
    let row = DeviceDiscovery.cameraRows(local: [], phones: [d], browsing: true).first { $0.kind == .phoneWiFi }!.rows[0]
    #expect(row.id == "phone:A" && !row.enabled && row.hint == "Update required")
}
