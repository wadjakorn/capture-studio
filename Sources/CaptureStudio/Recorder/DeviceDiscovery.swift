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

    var displayInfo: DisplayInfo {
        DisplayInfo(
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
