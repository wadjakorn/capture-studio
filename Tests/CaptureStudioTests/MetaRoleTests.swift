import Testing
import Foundation
@testable import CaptureStudio

@Suite struct MetaRoleTests {
    @Test func legacyMetaResolvesScreenAsMain() throws {
        let json = """
        {"schemaVersion":1,"app":{"version":"dev","macOSVersion":"15.0"},
         "display":{"displayID":1,"pixelWidth":100,"pixelHeight":50,"pointWidth":100,"pointHeight":50,"scaleFactor":1,"originX":0,"originY":0},
         "tracks":[{"type":"camera","filename":"camera.mp4","sessionStartHostTime":1,"codec":"h264","truncated":false},
                   {"type":"screen","filename":"screen.mp4","sessionStartHostTime":0,"codec":"hevc","truncated":false}],
         "recordedAt":"2026-01-01T00:00:00Z"}
        """
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let meta = try decoder.decode(ProjectMeta.self, from: Data(json.utf8))
        #expect(meta.mainTrack?.filename == "screen.mp4")
        #expect(meta.overlayCameraTrack?.filename == "camera.mp4")
        #expect(meta.isCameraMain == false)
        #expect(meta.mainSource == nil)
    }

    @Test func cameraMainResolvesByRole() {
        let main = TrackInfo(type: .camera, filename: "main-camera.mp4", sessionStartHostTime: 0, codec: "h264", role: .main)
        let overlay = TrackInfo(type: .camera, filename: "camera.mp4", sessionStartHostTime: 0.2, codec: "h264", role: .overlay)
        let meta = ProjectMeta(schemaVersion: 2, app: .current(), display: .synthetic(width: 1080, height: 1920),
                               tracks: [overlay, main], recordedAt: .now, mainSource: "camera")
        #expect(meta.mainTrack == main)
        #expect(meta.overlayCameraTrack == overlay)
        #expect(meta.isCameraMain)
    }

    @Test func roleRoundTripsAndOmitsWhenNil() throws {
        let t = TrackInfo(type: .screen, filename: "screen.mp4", sessionStartHostTime: 0, codec: "hevc")
        let data = try JSONEncoder().encode(t)
        #expect(!String(decoding: data, as: UTF8.self).contains("role"))
        let back = try JSONDecoder().decode(TrackInfo.self, from: data)
        #expect(back.role == nil)
    }

    @Test func roleAndMainSourceRoundTrip() throws {
        let t = TrackInfo(type: .camera, filename: "main-camera.mp4", sessionStartHostTime: 0, codec: "h264", role: .main)
        let back = try JSONDecoder().decode(TrackInfo.self, from: JSONEncoder().encode(t))
        #expect(back == t)
        let meta = ProjectMeta(schemaVersion: 2, app: .current(), display: .synthetic(width: 10, height: 20),
                               tracks: [t], recordedAt: Date(timeIntervalSince1970: 0), mainSource: "camera")
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        #expect(try dec.decode(ProjectMeta.self, from: enc.encode(meta)) == meta)
    }

    @Test func missingTruncatedDefaultsFalse() throws {
        let json = #"{"type":"screen","filename":"screen.mp4","sessionStartHostTime":0,"codec":"hevc"}"#
        let t = try JSONDecoder().decode(TrackInfo.self, from: Data(json.utf8))
        #expect(t.truncated == false)
    }

    @Test func syntheticDisplayInfo() {
        let d = DisplayInfo.synthetic(width: 1080, height: 1920)
        #expect(d.displayID == 0 && d.pixelWidth == 1080 && d.pointHeight == 1920 && d.scaleFactor == 1)
    }

    @Test func bundleURLs() {
        let b = ProjectBundle(url: URL(fileURLWithPath: "/tmp/x.capturestudio"))
        let t = TrackInfo(type: .camera, filename: "main-camera.mp4", sessionStartHostTime: 0, codec: "h264")
        #expect(b.url(for: t) == b.mainCameraURL)
        #expect(b.mainCameraURL.lastPathComponent == "main-camera.mp4")
    }
}
