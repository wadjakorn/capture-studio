import Testing
import CoreGraphics
@testable import CaptureStudio

/// The two rules an armed preview applies while the live area overlay is open:
/// whether Record may fire, and which display the recording targets.
///
/// Regression cover for a preview that could not be recorded. Both answers used to
/// be derived from "is a region selected right now?" when the real question is "is
/// a region *required*?" — only `.required` needs one. Full Display captures the
/// whole screen, an already-saved area is recordable as-is, and an armed session
/// always has a display even when the live selection names none.
@Suite struct ArmedRecordGateTests {

    // MARK: - Record gate

    @Test func fullDisplayRecordsWithNoRegion() {
        // Full Display's normal state is "no region". It must never block Record.
        #expect(RecordingSession.canBegin(areaSelection: .unavailable, region: nil))
    }

    @Test func savedAreaRecordsWithNoLiveRegion() {
        // A saved full-display area clamps its region to nil but keeps its display.
        // It is recordable as-is, so an empty live selection must not block it.
        #expect(RecordingSession.canBegin(areaSelection: .optional, region: nil))
    }

    @Test func savedAreaRecordsWithARegion() {
        #expect(RecordingSession.canBegin(
            areaSelection: .optional,
            region: CGRect(x: 0, y: 0, width: 640, height: 480)))
    }

    @Test func areaModeWithoutAnAreaCannotRecord() {
        // Area mode armed with no area at all stays blocked, so it can never
        // silently fall through to capturing the whole display.
        #expect(!RecordingSession.canBegin(areaSelection: .required, region: nil))
    }

    @Test func areaModeRecordsOnceAnAreaIsPicked() {
        #expect(RecordingSession.canBegin(
            areaSelection: .required,
            region: CGRect(x: 10, y: 10, width: 320, height: 200)))
    }

    // MARK: - Display target

    @Test func emptySelectionKeepsTheArmedDisplay() {
        // The overlay reports no display until a valid region is drawn. Adopting
        // that nil would erase the display the deferred screen recorder rebuilds
        // from, failing the record with "No area selected."
        #expect(RecordingSession.adoptedDisplay(current: 7, reported: nil) == 7)
    }

    @Test func selectionOnAnotherScreenMovesTheTarget() {
        #expect(RecordingSession.adoptedDisplay(current: 7, reported: 9) == 9)
    }

    @Test func firstSelectionSetsTheDisplayWhenNoneIsArmed() {
        #expect(RecordingSession.adoptedDisplay(current: nil, reported: 9) == 9)
    }
}
