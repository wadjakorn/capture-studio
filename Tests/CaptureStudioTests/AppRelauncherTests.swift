import Testing
@testable import CaptureStudio

@Test func relaunchPassesPathAsArgumentNotScript() {
    let path = "/Apps/My \"Odd\" App.app"
    let args = AppRelauncher.shellArguments(pid: 42, bundlePath: path)
    #expect(args.count == 4)
    #expect(args[0] == "-c")
    #expect(!args[1].contains("Odd"))   // path never interpolated into the script
    #expect(args[2] == "42")
    #expect(args[3] == path)
}

@Test func relaunchOnlyWhenNothingIsRecording() {
    #expect(AppRelauncher.isSafe(state: .idle))
    #expect(AppRelauncher.isSafe(state: .failed("x")))
    #expect(!AppRelauncher.isSafe(state: .armed))
    #expect(!AppRelauncher.isSafe(state: .recording(startedAt: .distantPast)))
    #expect(!AppRelauncher.isSafe(state: .finishing))
}
