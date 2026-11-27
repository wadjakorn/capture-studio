import CoreGraphics

/// Where an Area-mode start records, from the saved area and the displays that
/// are connected right now. Pure so the rule is testable without hardware.
///
/// `CGDirectDisplayID` is not stable: the same physical display can come back
/// with a different id after an external monitor is plugged/unplugged, after
/// clamshell, sleep or a reboot. So the saved area is matched by the display's
/// UUID (stable per physical display) first, and by the raw id only for areas
/// saved before the UUID was stored.
///
/// When the saved display really is gone, the area moves onto a live display
/// (the picker's, else the main one), shifted/shrunk to fit, and stays
/// recordable. The saved settings are left alone, so reconnecting the display
/// brings the area back where it was.
struct AreaTarget: Equatable {
    /// A display connected right now. `size` is in points.
    struct LiveDisplay: Equatable {
        let id: CGDirectDisplayID
        let uuid: String?
        let size: CGSize
    }

    /// Display to record. nil only when no display is connected at all.
    let displayID: CGDirectDisplayID?
    /// Display-local region; nil = full display (or nothing saved).
    let region: CGRect?
    let selection: AreaSelection
    /// The saved area's display isn't connected; the area was moved onto
    /// `displayID` instead.
    let movedFromMissingDisplay: Bool

    /// `live` is expected main display first (`DeviceDiscovery.liveDisplays()`).
    static func resolve(savedRegion: CGRect?, savedDisplayID: CGDirectDisplayID?,
                        savedDisplayUUID: String?, live: [LiveDisplay],
                        preferredFallback: CGDirectDisplayID?) -> AreaTarget {
        let fallback = live.first { $0.id == preferredFallback } ?? live.first

        // Nothing saved yet: select an area on the fallback display.
        if savedRegion == nil && savedDisplayID == nil && savedDisplayUUID == nil {
            return AreaTarget(displayID: fallback?.id ?? preferredFallback, region: nil,
                              selection: .required, movedFromMissingDisplay: false)
        }

        // The UUID is authoritative when present; the raw id only for legacy areas.
        let saved: LiveDisplay?
        if let uuid = savedDisplayUUID {
            saved = live.first { $0.uuid == uuid }
        } else if let id = savedDisplayID {
            saved = live.first { $0.id == id }
        } else {
            saved = nil  // legacy region saved before the display id was stored
        }
        if let saved {
            return AreaTarget(displayID: saved.id, region: savedRegion,
                              selection: .optional, movedFromMissingDisplay: false)
        }

        guard let fallback else {
            return AreaTarget(displayID: nil, region: nil, selection: .required,
                              movedFromMissingDisplay: savedDisplayID != nil || savedDisplayUUID != nil)
        }
        return AreaTarget(displayID: fallback.id,
                          region: savedRegion.map { fit($0, in: fallback.size) },
                          selection: .optional,
                          movedFromMissingDisplay: savedDisplayID != nil || savedDisplayUUID != nil)
    }

    /// Moves `region` inside a `size` display, shrinking it only if it's larger.
    static func fit(_ region: CGRect, in size: CGSize) -> CGRect {
        let w = min(region.width, size.width)
        let h = min(region.height, size.height)
        let x = min(max(region.minX, 0), size.width - w)
        let y = min(max(region.minY, 0), size.height - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

extension AreaTarget {
    /// The saved area resolved against the displays connected right now.
    /// Reads AppSettings fresh: the session writes a new drag there directly.
    static func current(preferredFallback: CGDirectDisplayID?) -> AreaTarget {
        resolve(savedRegion: AppSettings.captureRegion,
                savedDisplayID: AppSettings.captureRegionDisplayID,
                savedDisplayUUID: AppSettings.captureRegionDisplayUUID,
                live: DeviceDiscovery.liveDisplays(),
                preferredFallback: preferredFallback)
    }
}
