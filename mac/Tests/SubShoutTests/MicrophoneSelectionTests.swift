import XCTest
@testable import SubShout

final class MicrophoneSelectionTests: XCTestCase {
    func testDefaultFollowsCurrentSystemDevice() {
        for defaultID in ["built-in", "usb"] {
            let selection = MicrophoneSelection(
                preferredID: "", availableIDs: ["built-in", "usb"], defaultID: defaultID
            )
            XCTAssertEqual(selection.deviceID, defaultID)
            XCTAssertFalse(selection.usedFallback)
        }
    }

    func testPreferredMicrophoneOverridesSystemDefault() {
        let selection = MicrophoneSelection(
            preferredID: "usb", availableIDs: ["built-in", "usb"], defaultID: "built-in"
        )
        XCTAssertEqual(selection.deviceID, "usb")
        XCTAssertFalse(selection.usedFallback)
    }

    func testUnavailablePreferenceFallsBackAndReconnectRestoresIt() {
        let missing = MicrophoneSelection(
            preferredID: "usb", availableIDs: ["built-in"], defaultID: "built-in"
        )
        XCTAssertEqual(missing.deviceID, "built-in")
        XCTAssertTrue(missing.usedFallback)

        let reconnected = MicrophoneSelection(
            preferredID: "usb", availableIDs: ["built-in", "usb"], defaultID: "built-in"
        )
        XCTAssertEqual(reconnected.deviceID, "usb")
        XCTAssertFalse(reconnected.usedFallback)
    }

    func testNoSystemDefaultIsHandledWithoutInventingDevice() {
        let selection = MicrophoneSelection(preferredID: "usb", availableIDs: [], defaultID: nil)
        XCTAssertNil(selection.deviceID)
        XCTAssertTrue(selection.usedFallback)
        let system = MicrophoneSelection(preferredID: "", availableIDs: [], defaultID: nil)
        XCTAssertNil(system.deviceID)
        XCTAssertFalse(system.usedFallback)
    }

    func testPreferredDeviceDoesNotRequireSystemDefault() {
        let selection = MicrophoneSelection(
            preferredID: "usb", availableIDs: ["usb"], defaultID: nil
        )
        XCTAssertEqual(selection.deviceID, "usb")
        XCTAssertFalse(selection.usedFallback)
    }

    func testMicrophoneSettingPersistsAndCanReturnToDefault() {
        let suiteName = "subshout.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.microphoneID, "")
        settings.microphoneID = "persistent-usb-id"
        XCTAssertEqual(AppSettings(defaults: defaults).microphoneID, "persistent-usb-id")
        settings.microphoneID = ""
        XCTAssertEqual(AppSettings(defaults: defaults).microphoneID, "")
    }
}
