import AppKit
import Foundation

/// Tiny wrapper over the two system sounds we use as start/stop cues.
///
/// We pre-load both `NSSound`s once and reuse them.  `NSSound(named:)` was
/// considered (e.g. `NSSound(named: "Tink")`) but the AIFFs at
/// `/System/Library/Sounds/*.aiff` are the canonical source and they're
/// guaranteed present on macOS 13+.
enum Sounds {
    private static let tink: NSSound? = NSSound(
        contentsOfFile: "/System/Library/Sounds/Tink.aiff", byReference: true
    )
    private static let pop: NSSound? = NSSound(
        contentsOfFile: "/System/Library/Sounds/Pop.aiff", byReference: true
    )

    static func start() {
        // `play()` is non-blocking and re-entrant if the sound is already playing.
        tink?.stop()
        tink?.play()
    }

    static func stop() {
        pop?.stop()
        pop?.play()
    }
}
