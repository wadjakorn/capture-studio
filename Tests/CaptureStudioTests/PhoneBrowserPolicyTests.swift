import Testing
import Network
@testable import CaptureStudio

@Test func policyDeniedDNSErrorIsLocalNetworkDenial() {
    #expect(PhoneBrowser.isLocalNetworkDenied(.dns(-65570)))
}

@Test func otherErrorsAreNotLocalNetworkDenial() {
    #expect(!PhoneBrowser.isLocalNetworkDenied(.dns(-65537)))       // kDNSServiceErr_Unknown
    #expect(!PhoneBrowser.isLocalNetworkDenied(.posix(.ECONNREFUSED)))
}
