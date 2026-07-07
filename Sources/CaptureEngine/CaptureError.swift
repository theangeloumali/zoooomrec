import Foundation

/// Errors surfaced by the capture packet. `screenRecordingPermissionDenied` is the
/// one the CLI translates into actionable System Settings guidance.
public enum CaptureError: Error, CustomStringConvertible {
  case screenRecordingPermissionDenied
  case noDisplayAvailable
  case assetWriterFailed(String)

  public var description: String {
    switch self {
    case .screenRecordingPermissionDenied:
      return "screen recording permission denied"
    case .noDisplayAvailable:
      return "no display available to capture"
    case .assetWriterFailed(let reason):
      return "asset writer failed: \(reason)"
    }
  }
}
