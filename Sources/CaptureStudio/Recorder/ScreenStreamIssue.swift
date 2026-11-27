import Foundation
import ScreenCaptureKit

/// Why the screen SCStream stopped on its own mid-recording. Pure: the
/// Screen Recording grant is injected so tests need no TCC.
enum ScreenStreamIssue: Equatable, Sendable {
    /// The user ended the capture from the system UI — a normal stop.
    case userStopped
    case permissionRevoked
    case displayLost
    case systemStopped
    case other(String)

    /// `.userStopped` wins regardless of the grant; then a missing grant beats
    /// any error code (a revoked grant surfaces under several codes).
    static func classify(_ error: Error, screenAccessGranted: Bool) -> ScreenStreamIssue {
        let nsError = error as NSError
        let code = nsError.domain == SCStreamErrorDomain
            ? SCStreamError.Code(rawValue: nsError.code) : nil
        if code == .userStopped { return .userStopped }
        if !screenAccessGranted { return .permissionRevoked }
        switch code {
        case .userDeclined, .missingEntitlements:
            return .permissionRevoked
        case .noDisplayList, .noCaptureSource:
            return .displayLost
        case .systemStoppedStream, .failedApplicationConnectionInterrupted:
            return .systemStopped
        default:
            return .other(error.localizedDescription)
        }
    }

    /// Failure text shown after the partial take was saved.
    var savedMessage: String {
        switch self {
        case .permissionRevoked:
            return "Screen Recording access was turned off. The recording was saved up to that point."
        case .displayLost:
            return "The display was disconnected. The recording was saved up to that point."
        case .systemStopped:
            return "macOS stopped the screen capture. The recording was saved up to that point."
        case .other(let description):
            return "Recording saved, but capture stopped early: \(description)"
        case .userStopped:
            // Never shown: a user stop finishes as a normal stop.
            return "Screen sharing was stopped."
        }
    }

    /// The permission to fix, if this stop was caused by a revoked grant.
    var permission: PermissionKind? {
        self == .permissionRevoked ? .screenRecording : nil
    }
}

/// `stop(streamError:)` payload for a classified screen-stream stop.
struct ScreenStreamFailure: LocalizedError {
    let issue: ScreenStreamIssue
    var errorDescription: String? { issue.savedMessage }
}
