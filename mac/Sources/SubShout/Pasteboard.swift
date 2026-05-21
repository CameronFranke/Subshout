import AppKit
import Foundation

/// Clipboard write + ⌘V synthesis.
///
/// The decision (TODO.md) is to leave the text on the clipboard after
/// pasting — no clipboard restore.  This gives the user "I just dictated,
/// now I can paste again into another app."
enum Pasteboard {
    /// Copy `text` to the general pasteboard and synthesize ⌘V at the
    /// current focus.  Returns `true` if the keystroke was posted (we
    /// can't tell from CGEventPost whether the target app actually
    /// accepted the paste).
    @discardableResult
    static func copyAndPaste(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        return synthesizeCmdV()
    }

    /// Just copy.  Used as a fallback if pasting is disabled or accessibility
    /// hasn't been granted.
    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private static func synthesizeCmdV() -> Bool {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 0x09  // kVK_ANSI_V
        guard
            let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true),
            let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        // Annotated session tap is what other apps observe; this is what
        // ⌘V from the keyboard hardware would post.
        let tap = CGEventTapLocation.cgAnnotatedSessionEventTap
        down.post(tap: tap)
        up.post(tap: tap)
        return true
    }
}
