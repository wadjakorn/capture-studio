import Testing
@testable import CaptureStudio

@Test func phoneMicRidesOnSamePhoneVideo() {
    let p = RecorderSelection.phonePlan(main: .camera(uniqueID: "phone:A"), cameraID: nil, micID: "phone-mic:A")
    #expect(p.mainPhone == "A" && p.micPhone == "A" && p.micHost == .mainRecorder)
}
@Test func phoneMicAloneIsStandalone() {
    #expect(RecorderSelection.phonePlan(main: .display(1), cameraID: nil, micID: "phone-mic:A").micHost == .standalonePhone)
}
@Test func phoneVideoLocalMic() {
    let p = RecorderSelection.phonePlan(main: .display(1), cameraID: "phone:A", micID: "builtin")
    #expect(p.overlayPhone == "A" && p.micHost == .local)
}
@Test func differentPhonesRejected() {
    #expect(RecorderSelection.phonePlan(main: .camera(uniqueID: "phone:A"), cameraID: nil, micID: "phone-mic:B").micHost == .none)
}
