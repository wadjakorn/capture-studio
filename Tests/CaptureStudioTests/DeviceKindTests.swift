import Testing
@testable import CaptureStudio

@Test func continuityCameraIsPhone() {
    #expect(DeviceKind.classify(name: "iPhone", manufacturer: "Apple Inc.", modelID: "Continuity Camera",
                                deviceType: "AVCaptureDeviceTypeContinuityCamera") == .phone)
}
@Test func galaxyUVCIsPhone() {
    #expect(DeviceKind.classify(name: "Galaxy S26 Ultra", manufacturer: "Samsung", modelID: "UVC Camera VendorID_1256",
                                deviceType: "AVCaptureDeviceTypeExternal") == .phone)
}
@Test func iriunIsPhone() {
    #expect(DeviceKind.classify(name: "Iriun Webcam", manufacturer: nil, modelID: nil,
                                deviceType: "AVCaptureDeviceTypeExternal") == .phone)
}
@Test func obsVirtualIsVirtual() {
    #expect(DeviceKind.classify(name: "OBS Virtual Camera", manufacturer: nil, modelID: nil,
                                deviceType: "AVCaptureDeviceTypeExternal") == .virtual)
}
@Test func logitechIsExternal() {
    #expect(DeviceKind.classify(name: "Logitech BRIO", manufacturer: "Logitech", modelID: "UVC Camera VendorID_1133",
                                deviceType: "AVCaptureDeviceTypeExternal") == .external)
}
@Test func macbookMicIsBuiltIn() {
    #expect(DeviceKind.classify(name: "MacBook Pro Microphone", manufacturer: "Apple Inc.", modelID: nil,
                                deviceType: "AVCaptureDeviceTypeMicrophone") == .builtIn)
}
@Test func facetimeIsBuiltIn() {
    #expect(DeviceKind.classify(name: "FaceTime HD Camera", manufacturer: "Apple Inc.", modelID: "FaceTime HD Camera",
                                deviceType: "AVCaptureDeviceTypeBuiltInWideAngleCamera") == .builtIn)
}
@Test func groupTitles() {
    #expect(DeviceKind.allCases.map(\.groupTitle) == ["Built-in", "Phone", "External", "Virtual"])
}
