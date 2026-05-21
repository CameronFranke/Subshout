import XCTest
@testable import SubShout
import CoreGraphics

/// Coverage for the `HotkeyManager.Trigger` equality logic — specifically
/// the `relevantBits` filter that ignores incidental modifier bits (like
/// `maskNumericPad`) when comparing combos.  The state-machine itself
/// needs a CGEventTap which we can't fake in a unit test, but the equality
/// rules are pure data and worth pinning.
final class HotkeyTriggerTests: XCTestCase {

    func testRelevantBitsKeepsCommandShiftAlternateControl() {
        let bits: CGEventFlags = [
            .maskCommand, .maskShift, .maskAlternate, .maskControl,
        ]
        let kept = HotkeyManager.Trigger.relevantBits(bits)
        XCTAssertEqual(kept, bits.rawValue)
    }

    func testRelevantBitsDropsNumericPad() {
        // maskNumericPad is irrelevant for our hotkey matching — the user
        // never picks "⌘ on the numpad" vs "⌘ on the main keyboard" as
        // distinct bindings.
        let bits = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue
                                | CGEventFlags.maskNumericPad.rawValue)
        let kept = HotkeyManager.Trigger.relevantBits(bits)
        XCTAssertEqual(kept, CGEventFlags.maskCommand.rawValue)
    }

    func testEqualityIgnoresIrrelevantBits() {
        // Same key, same logical modifiers, but one carries the numeric
        // pad bit.  They must compare equal.
        let a = HotkeyManager.Trigger.keyCombo(
            keyCode: 0x09, modifiers: .maskCommand
        )
        let b = HotkeyManager.Trigger.keyCombo(
            keyCode: 0x09,
            modifiers: CGEventFlags(rawValue:
                CGEventFlags.maskCommand.rawValue
                | CGEventFlags.maskNumericPad.rawValue
            )
        )
        XCTAssertEqual(a, b)
    }

    func testEqualityDistinguishesDifferentModifiers() {
        let a = HotkeyManager.Trigger.keyCombo(keyCode: 0x09, modifiers: .maskCommand)
        let b = HotkeyManager.Trigger.keyCombo(keyCode: 0x09, modifiers: .maskAlternate)
        XCTAssertNotEqual(a, b)
    }

    func testEqualityDistinguishesSingleVsDoubleTap() {
        let a = HotkeyManager.Trigger.modifierSingleTap(keyCode: 58)
        let b = HotkeyManager.Trigger.modifierDoubleTap(keyCode: 58)
        XCTAssertNotEqual(a, b)
    }

    func testEqualityMatchesSameTapKind() {
        let a = HotkeyManager.Trigger.modifierDoubleTap(keyCode: 58)
        let b = HotkeyManager.Trigger.modifierDoubleTap(keyCode: 58)
        XCTAssertEqual(a, b)
    }

    func testDefaultTriggerIsLeftOptionDoubleTap() {
        // Tied to TODO.md.  Pin so we don't
        // accidentally change the default.
        XCTAssertEqual(HotkeyManager.defaultTrigger,
                       .modifierDoubleTap(keyCode: 58))
    }

    func testDoubleTapWindowMatchesSpec() {
        XCTAssertEqual(HotkeyManager.doubleTapWindow, 0.3, accuracy: 0.001)
    }
}
