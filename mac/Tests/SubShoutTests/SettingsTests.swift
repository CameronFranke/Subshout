import XCTest
@testable import SubShout

/// Cover the Codable round-trip for `TriggerSpec` (UserDefaults-backed)
/// and the human-label rendering used by the menu / settings.
///
/// `AppSettings` itself isn't tested directly here because it touches
/// `UserDefaults.standard` and `LoginItem`/`SMAppService` (which can't
/// be exercised reliably outside a real .app bundle on the CI runner).
final class SettingsTests: XCTestCase {

    // MARK: - TriggerSpec encode/decode

    func testTriggerSpecCodableRoundTripModifierDoubleTap() throws {
        let original: TriggerSpec = .modifierDoubleTap(keyCode: 58)  // left option
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TriggerSpec.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testTriggerSpecCodableRoundTripModifierSingleTap() throws {
        let original: TriggerSpec = .modifierSingleTap(keyCode: 61)  // right option
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TriggerSpec.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testTriggerSpecCodableRoundTripKeyCombo() throws {
        // 0x080000 = maskAlternate, 0x100000 = maskCommand.  Pin the
        // serialized representation by reading it back and checking
        // both the combo shape and the modifier bits.
        let original: TriggerSpec = .keyCombo(keyCode: 0x09, modifiers: 0x080000 | 0x100000)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TriggerSpec.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    // MARK: - UserDefaults persistence helpers

    func testTriggerSpecPersistAndLoad() {
        // Use a private suite so we don't pollute the test runner's
        // standard defaults.
        let suiteName = "subshout.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let spec: TriggerSpec = .keyCombo(keyCode: 36, modifiers: 0x100000)  // ⌘ Return
        TriggerSpec.persist(spec, to: defaults, key: "x")

        let loaded = TriggerSpec.load(from: defaults, key: "x")
        XCTAssertEqual(loaded, spec)
    }

    func testTriggerSpecLoadReturnsNilForMissingKey() {
        let suiteName = "subshout.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertNil(TriggerSpec.load(from: defaults, key: "nope"))
    }

    func testTriggerSpecLoadReturnsNilForGarbage() {
        let suiteName = "subshout.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(Data([0xff, 0xfe, 0xfd]), forKey: "y")
        XCTAssertNil(TriggerSpec.load(from: defaults, key: "y"))
    }

    // MARK: - Convenience properties

    func testIsModifierTap() {
        XCTAssertTrue(TriggerSpec.modifierSingleTap(keyCode: 58).isModifierTap)
        XCTAssertTrue(TriggerSpec.modifierDoubleTap(keyCode: 58).isModifierTap)
        XCTAssertFalse(TriggerSpec.keyCombo(keyCode: 0x09, modifiers: 0x100000).isModifierTap)
    }

    func testModifierKeyCode() {
        XCTAssertEqual(TriggerSpec.modifierSingleTap(keyCode: 58).modifierKeyCode, 58)
        XCTAssertEqual(TriggerSpec.modifierDoubleTap(keyCode: 61).modifierKeyCode, 61)
        XCTAssertNil(TriggerSpec.keyCombo(keyCode: 0x09, modifiers: 0).modifierKeyCode)
    }

    // MARK: - Human labels

    func testHumanLabelLeftOptionDoubleTap() {
        // The default binding's label has to actually say "Left ⌥" for
        // the menu hint to be useful.
        let spec: TriggerSpec = .modifierDoubleTap(keyCode: 58)
        XCTAssertEqual(spec.humanLabel, "Double-tap Left ⌥")
    }

    func testHumanLabelKeyCombo() {
        // ⌘V (maskCommand = 0x100000, V = 0x09).
        let spec: TriggerSpec = .keyCombo(keyCode: 0x09, modifiers: 0x100000)
        // The order produced by KeyName.modifierFlags is ⌃⌥⇧⌘, so just ⌘.
        // V isn't in our hand-rolled table — it falls back to the hex form.
        XCTAssertTrue(spec.humanLabel.hasPrefix("⌘"), "got \(spec.humanLabel)")
    }

    func testHumanLabelUnknownKeyFallback() {
        // Keys we don't recognize render as a hex placeholder so the user
        // can still see something — and rebind from the UI.
        let spec: TriggerSpec = .modifierDoubleTap(keyCode: 0xAB)
        XCTAssertEqual(spec.humanLabel, "Double-tap Key 0xab")
    }

    // MARK: - KeyName

    func testKeyNameModifierKnown() {
        XCTAssertEqual(KeyName.modifier(for: 58), "Left ⌥")
        XCTAssertEqual(KeyName.modifier(for: 61), "Right ⌥")
        XCTAssertEqual(KeyName.modifier(for: 55), "Left ⌘")
    }

    func testKeyNameModifierFallback() {
        XCTAssertEqual(KeyName.modifier(for: 0x42), "Key 0x42")
    }

    func testKeyNameModifierFlagsOrder() {
        // Order is fixed: ⌃ ⌥ ⇧ ⌘.  Pin it.
        let all: UInt64 = 0x040000 | 0x080000 | 0x020000 | 0x100000
        XCTAssertEqual(KeyName.modifierFlags(all), "⌃⌥⇧⌘")
    }

    func testKeyNameModifierFlagsNone() {
        XCTAssertEqual(KeyName.modifierFlags(0), "")
    }

    // MARK: - Bridge to HotkeyManager.Trigger

    func testAsTriggerRoundTripModifierDoubleTap() {
        let spec: TriggerSpec = .modifierDoubleTap(keyCode: 58)
        let trig = spec.asTrigger
        let back = TriggerSpec(trig)
        XCTAssertEqual(spec, back)
    }

    func testAsTriggerRoundTripKeyCombo() {
        let spec: TriggerSpec = .keyCombo(keyCode: 36, modifiers: 0x100000)
        let trig = spec.asTrigger
        let back = TriggerSpec(trig)
        XCTAssertEqual(spec, back)
    }
}
