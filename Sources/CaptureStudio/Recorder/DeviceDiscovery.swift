import Foundation
import ScreenCaptureKit
import AVFoundation
import AppKit

/// A recordable display with resolved name and pixel geometry.
struct DisplayItem: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
    let pointWidth: Double
    let pointHeight: Double
    let pixelWidth: Int
    let pixelHeight: Int
    let originX: Double
    let originY: Double

    var scaleFactor: Double {
        pointWidth > 0 ? Double(pixelWidth) / pointWidth : 1
    }

    var displayInfo: DisplayInfo { displayInfo(region: nil) }

    /// Captured pixel size for either the full display or a sub-region (in
    /// display-local points). Single-sources the capture-size math so the
    /// recorder's SCStream config and the persisted DisplayInfo always agree.
    func capturePixelSize(region: CGRect?) -> (width: Int, height: Int) {
        guard let region else {
            return ScreenRecorder.captureSize(forWidth: pixelWidth, height: pixelHeight)
        }
        let w = Int((region.width * scaleFactor).rounded())
        let h = Int((region.height * scaleFactor).rounded())
        return ScreenRecorder.captureSize(forWidth: max(1, w), height: max(1, h))
    }

    /// Geometry written into meta.json. With a region, the values describe the
    /// captured sub-rectangle (origin = display origin + region origin, point
    /// size = region size, pixel size = actual capture). Every Studio coordinate
    /// transform derives from these fields + the screen.mp4 natural size, so it
    /// stays correct for the region with no Studio-side change. region nil →
    /// full-display values (identical to before).
    func displayInfo(region: CGRect?) -> DisplayInfo {
        guard let region else {
            return DisplayInfo(
                displayID: id,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                pointWidth: pointWidth,
                pointHeight: pointHeight,
                scaleFactor: scaleFactor,
                originX: originX,
                originY: originY
            )
        }
        let px = capturePixelSize(region: region)
        let regionScale = region.width > 0 ? Double(px.width) / region.width : scaleFactor
        return DisplayInfo(
            displayID: id,
            pixelWidth: px.width,
            pixelHeight: px.height,
            pointWidth: region.width,
            pointHeight: region.height,
            scaleFactor: regionScale,
            originX: originX + region.origin.x,
            originY: originY + region.origin.y
        )
    }

    /// Clamps a saved region (display-local points) to this display's bounds.
    /// Returns nil if the region doesn't overlap or already covers the full
    /// display — defends against a region saved for a different/resized display.
    func clampedRegion(_ region: CGRect?) -> CGRect? {
        guard let region else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: pointWidth, height: pointHeight)
        let clamped = region.intersection(bounds)
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1 else { return nil }
        if clamped == bounds { return nil }  // full display → no region
        return clamped
    }
}

/// Where a capture device comes from, for grouping in the recorder's pickers.
enum DeviceKind: String, CaseIterable {
    case builtIn, phone, external, virtual
}

extension DeviceKind {
    private static let builtInNames = ["macbook", "imac", "mac mini", "mac studio", "built-in"]
    private static let phoneHints = ["samsung", "galaxy", "android", "iriun", "droidcam", "camo",
                                     "epoccam", "iphone", "ipad", "pixel"]
    private static let virtualHints = ["virtual", "obs", "snap camera", "mmhmm"]

    /// Pure. `deviceType` is the raw `AVCaptureDevice.DeviceType.rawValue`.
    static func classify(name: String, manufacturer: String?, modelID: String?,
                         deviceType: String) -> DeviceKind {
        if deviceType == AVCaptureDevice.DeviceType.continuityCamera.rawValue { return .phone }
        if deviceType == AVCaptureDevice.DeviceType.builtInWideAngleCamera.rawValue
            || deviceType.hasPrefix("AVCaptureDeviceTypeBuiltIn") { return .builtIn }
        let lowerName = name.lowercased()
        // Microphones report deviceType `.microphone`, never built-in, so go by name.
        if builtInNames.contains(where: lowerName.contains) { return .builtIn }
        let haystack = [name, manufacturer ?? "", modelID ?? ""].joined(separator: " ").lowercased()
        if phoneHints.contains(where: haystack.contains) { return .phone }
        if virtualHints.contains(where: haystack.contains) { return .virtual }
        return .external
    }

    var groupTitle: String {
        switch self {
        case .builtIn: "Built-in"
        case .phone: "Phone"
        case .external: "External"
        case .virtual: "Virtual"
        }
    }
}

enum DeviceDiscovery {
    /// Enumerates displays via ScreenCaptureKit. Throws if Screen Recording
    /// permission is missing (first call also triggers the TCC prompt).
    static func displays() async throws -> (items: [DisplayItem], scDisplays: [CGDirectDisplayID: SCDisplay]) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        var items: [DisplayItem] = []
        var map: [CGDirectDisplayID: SCDisplay] = [:]
        for display in content.displays {
            let mode = CGDisplayCopyDisplayMode(display.displayID)
            items.append(DisplayItem(
                id: display.displayID,
                name: displayName(for: display.displayID),
                pointWidth: Double(display.width),
                pointHeight: Double(display.height),
                pixelWidth: mode?.pixelWidth ?? display.width,
                pixelHeight: mode?.pixelHeight ?? display.height,
                originX: display.frame.origin.x,
                originY: display.frame.origin.y
            ))
            map[display.displayID] = display
        }
        return (items, map)
    }

    /// Cameras: built-in, external/USB, and Continuity Camera.
    static func cameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    /// Microphones (includes USB and camera-attached mics).
    static func microphones() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    private static func displayName(for displayID: CGDirectDisplayID) -> String {
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
               number.uint32Value == displayID {
                return screen.localizedName
            }
        }
        return "Display \(displayID)"
    }
}

extension DeviceDiscovery {
    static func kind(of device: AVCaptureDevice) -> DeviceKind {
        DeviceKind.classify(name: device.localizedName, manufacturer: device.manufacturer,
                            modelID: device.modelID, deviceType: device.deviceType.rawValue)
    }

    /// Stable group order: builtIn, phone, external, virtual; name order within.
    /// Empty groups are omitted.
    static func grouped(_ devices: [AVCaptureDevice]) -> [(kind: DeviceKind, devices: [AVCaptureDevice])] {
        DeviceKind.allCases.compactMap { kind in
            let members = devices
                .filter { self.kind(of: $0) == kind }
                .sorted { $0.localizedName.localizedStandardCompare($1.localizedName) == .orderedAscending }
            return members.isEmpty ? nil : (kind: kind, devices: members)
        }
    }
}
