import Testing
import Foundation
@testable import CaptureStudio

struct CropAspectTests {
    @Test func templateRatioMatchesNineBySixteen() {
        #expect(CropAspect.nineBySixteenTemplate.ratio == 9.0 / 16.0)
        #expect(CropAspect.nineBySixteen.ratio == 9.0 / 16.0)
    }

    @Test func onlyTemplateIsFit() {
        #expect(CropAspect.nineBySixteenTemplate.isFit == true)
        for a in CropAspect.allCases where a != .nineBySixteenTemplate {
            #expect(a.isFit == false)
        }
    }

    @Test func templateDisplayNameIsRawValue() {
        #expect(CropAspect.nineBySixteenTemplate.displayName == "9:16 with template")
    }

    @Test func templateDecodesFromRawValue() {
        #expect(CropAspect(rawValue: "9:16 with template") == .nineBySixteenTemplate)
    }
}
