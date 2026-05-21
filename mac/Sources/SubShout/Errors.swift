import Foundation

/// Anything subshout-specific that doesn't already have a Foundation/Darwin
/// error type.  Keep this list short — most failures should map to existing
/// types (`POSIXError`, `CocoaError`, `NSError` from a system framework).
enum SubShoutError: LocalizedError, Equatable {
    case socketPathTooLong(String)
    case daemonNotFound(String)
    case daemonProtocol(String)
    case daemonResponse(code: String, message: String)
    case audioEngineFailed(String)
    case microphoneDenied
    case accessibilityDenied

    var errorDescription: String? {
        switch self {
        case .socketPathTooLong(let p):
            return "Unix socket path is too long for sun_path: \(p)"
        case .daemonNotFound(let why):
            return "Could not find shout-daemon: \(why)"
        case .daemonProtocol(let why):
            return "Daemon protocol error: \(why)"
        case .daemonResponse(let code, let message):
            return "Daemon error (\(code)): \(message)"
        case .audioEngineFailed(let why):
            return "Audio engine failed: \(why)"
        case .microphoneDenied:
            return "Microphone access denied. Enable it in System Settings → Privacy & Security → Microphone."
        case .accessibilityDenied:
            return "Accessibility access denied. Enable it in System Settings → Privacy & Security → Accessibility."
        }
    }
}
