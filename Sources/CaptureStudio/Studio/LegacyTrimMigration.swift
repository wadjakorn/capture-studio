import Foundation

/// Pure. Lift an `EditState` saved against the committed-trim window onto the
/// full master timeline: blocks/subtitle offset shift by `committedTrimStart`;
/// the window edges and the live In/Out markers become hidden segments.
/// Output has committedTrimStart == 0, committedTrimEnd == nil, trimIn == 0,
/// trimOut == nil. Idempotent: a state with no legacy trim is returned as is.
enum LegacyTrimMigration {
    static func migrate(_ edit: EditState, masterDuration: Double) -> EditState {
        let master = max(0, masterDuration)
        let cs = min(max(edit.committedTrimStart, 0), master)
        let ce = min(max(edit.committedTrimEnd ?? master, cs), master)
        if cs == 0 && ce == master && edit.trimIn == 0 && edit.trimOut == nil { return edit }

        var e = edit
        e.cameraBlocks = edit.cameraBlocks.map { var b = $0; b.begin += cs; b.end += cs; return b }
        e.layoutBlocks = edit.layoutBlocks.map { var b = $0; b.begin += cs; b.end += cs; return b }
        e.zoomBlocks = edit.zoomBlocks.map { var b = $0; b.begin += cs; b.end += cs; return b }
        e.textBlocks = edit.textBlocks.map { var b = $0; b.begin += cs; b.end += cs; return b }
        e.shapeBlocks = edit.shapeBlocks.map { var b = $0; b.begin += cs; b.end += cs; return b }
        if var track = edit.subtitles {
            track.offset += cs
            e.subtitles = track
        }

        var segs: [TimelineSegment]
        if edit.segments.isEmpty {
            segs = TimelineSegments.full(duration: master)
        } else {
            let shifted = edit.segments.map {
                TimelineSegment(id: $0.id, start: $0.start + cs, end: $0.end + cs, hidden: $0.hidden)
            }
            segs = TimelineSegments.normalized(shifted, duration: master)
        }
        if cs > 0 { segs = TimelineSegments.cut(segs, range: 0 ..< cs) }
        if ce < master { segs = TimelineSegments.cut(segs, range: ce ..< master) }

        // Live markers: legacy load rule ignores them when trimOut <= trimIn.
        let tin = min(max(cs + edit.trimIn, cs), ce)
        let tout = min(max(cs + (edit.trimOut ?? (ce - cs)), cs), ce)
        if tout > tin {
            if tin > cs { segs = TimelineSegments.cut(segs, range: cs ..< tin) }
            if tout < ce { segs = TimelineSegments.cut(segs, range: tout ..< ce) }
        }

        e.committedTrimStart = 0
        e.committedTrimEnd = nil
        e.trimIn = 0
        e.trimOut = nil
        e.segments = TimelineSegments.uncutIfSingleVisible(segs)
        return e
    }
}
