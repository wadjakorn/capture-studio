import Testing
import CoreGraphics
@testable import CaptureStudio

private let region = CGRect(x: 494, y: 234, width: 953, height: 724)
private let builtIn = AreaTarget.LiveDisplay(id: 1, uuid: "BUILTIN", size: CGSize(width: 1512, height: 982))
private let external = AreaTarget.LiveDisplay(id: 2, uuid: "EXT", size: CGSize(width: 2560, height: 1440))
private let small = AreaTarget.LiveDisplay(id: 4, uuid: "SMALL", size: CGSize(width: 800, height: 600))

@Test func areaOnConnectedDisplayIsReused() {
    let t = AreaTarget.resolve(savedRegion: region, savedDisplayID: 2, savedDisplayUUID: "EXT",
                               live: [builtIn, external], preferredFallback: 1)
    #expect(t == AreaTarget(displayID: 2, region: region, selection: .optional,
                            movedFromMissingDisplay: false))
}

// The reported bug: the built-in display was id 3 when the area was dragged and
// is id 1 now. Same physical display → same UUID → same area, new id.
@Test func sameDisplayWithNewIDIsFoundByUUID() {
    let t = AreaTarget.resolve(savedRegion: region, savedDisplayID: 3, savedDisplayUUID: "BUILTIN",
                               live: [builtIn], preferredFallback: 1)
    #expect(t == AreaTarget(displayID: 1, region: region, selection: .optional,
                            movedFromMissingDisplay: false))
}

// A stale id now belonging to another display must not win over the UUID.
@Test func uuidBeatsAReusedID() {
    let t = AreaTarget.resolve(savedRegion: region, savedDisplayID: 2, savedDisplayUUID: "BUILTIN",
                               live: [builtIn, external], preferredFallback: 2)
    #expect(t.displayID == 1)
    #expect(!t.movedFromMissingDisplay)
}

@Test func fullDisplayAreaOnConnectedDisplayIsReused() {
    let t = AreaTarget.resolve(savedRegion: nil, savedDisplayID: 2, savedDisplayUUID: "EXT",
                               live: [builtIn, external], preferredFallback: 1)
    #expect(t == AreaTarget(displayID: 2, region: nil, selection: .optional,
                            movedFromMissingDisplay: false))
}

// Legacy (no UUID saved) with an id that isn't connected — the user's state
// before this fix — still records, on the fallback display.
@Test func legacyMissingIDMovesOntoFallback() {
    let t = AreaTarget.resolve(savedRegion: region, savedDisplayID: 3, savedDisplayUUID: nil,
                               live: [builtIn], preferredFallback: 1)
    #expect(t == AreaTarget(displayID: 1, region: region, selection: .optional,
                            movedFromMissingDisplay: true))
}

@Test func legacyConnectedIDIsReused() {
    let t = AreaTarget.resolve(savedRegion: region, savedDisplayID: 2, savedDisplayUUID: nil,
                               live: [builtIn, external], preferredFallback: 1)
    #expect(t.displayID == 2)
    #expect(!t.movedFromMissingDisplay)
}

@Test func disconnectedDisplayPrefersThePickersDisplay() {
    let t = AreaTarget.resolve(savedRegion: region, savedDisplayID: 9, savedDisplayUUID: "GONE",
                               live: [builtIn, external], preferredFallback: 2)
    #expect(t == AreaTarget(displayID: 2, region: region, selection: .optional,
                            movedFromMissingDisplay: true))
}

@Test func disconnectedDisplayFallsBackToMainWhenPickerIsGone() {
    let t = AreaTarget.resolve(savedRegion: region, savedDisplayID: 9, savedDisplayUUID: "GONE",
                               live: [builtIn, external], preferredFallback: 9)
    #expect(t.displayID == 1)
    #expect(t.movedFromMissingDisplay)
}

@Test func movedAreaIsFittedOntoASmallerDisplay() {
    let t = AreaTarget.resolve(savedRegion: region, savedDisplayID: 2, savedDisplayUUID: "EXT",
                               live: [small], preferredFallback: nil)
    #expect(t.displayID == 4)
    #expect(t.region == CGRect(x: 0, y: 0, width: 800, height: 600))
    #expect(t.selection == .optional)
}

@Test func noSavedAreaRequiresSelectionOnFallback() {
    let t = AreaTarget.resolve(savedRegion: nil, savedDisplayID: nil, savedDisplayUUID: nil,
                               live: [builtIn, external], preferredFallback: 2)
    #expect(t == AreaTarget(displayID: 2, region: nil, selection: .required,
                            movedFromMissingDisplay: false))
}

// Region saved before the display id was stored keeps today's behavior.
@Test func regionWithoutDisplayUsesFallback() {
    let t = AreaTarget.resolve(savedRegion: region, savedDisplayID: nil, savedDisplayUUID: nil,
                               live: [builtIn], preferredFallback: 1)
    #expect(t == AreaTarget(displayID: 1, region: region, selection: .optional,
                            movedFromMissingDisplay: false))
}

@Test func fitShiftsBeforeShrinking() {
    let r = AreaTarget.fit(CGRect(x: 2000, y: 900, width: 400, height: 300),
                           in: CGSize(width: 1512, height: 982))
    #expect(r == CGRect(x: 1112, y: 682, width: 400, height: 300))
}

@Test func fitKeepsAnAreaThatAlreadyFits() {
    #expect(AreaTarget.fit(region, in: builtIn.size) == region)
}
