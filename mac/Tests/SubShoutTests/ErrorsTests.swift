import XCTest
@testable import SubShout

/// `SubShoutError` descriptions appear in the menu bar and the Settings
/// "last error" line, so we pin the user-facing copy to keep it
/// human-readable.  Test failures here are intentional — if you change a
/// message, also change the test.
final class ErrorsTests: XCTestCase {

    func testMicrophoneDeniedHasActionableCopy() {
        let desc = SubShoutError.microphoneDenied.errorDescription ?? ""
        XCTAssertTrue(desc.contains("Microphone"), "lost the noun: \(desc)")
        XCTAssertTrue(desc.contains("System Settings"), "no path to fix: \(desc)")
    }

    func testAccessibilityDeniedHasActionableCopy() {
        let desc = SubShoutError.accessibilityDenied.errorDescription ?? ""
        XCTAssertTrue(desc.contains("Accessibility"), "lost the noun: \(desc)")
        XCTAssertTrue(desc.contains("System Settings"), "no path to fix: \(desc)")
    }

    func testDaemonResponseFormatsCodeAndMessage() {
        let err = SubShoutError.daemonResponse(code: "busy", message: "another client is connected")
        let desc = err.errorDescription ?? ""
        XCTAssertTrue(desc.contains("busy"))
        XCTAssertTrue(desc.contains("another client"))
    }

    func testEquatable() {
        // `Equatable` matters because tests above expect == over enum
        // payloads.  Sanity-check one match and one mismatch.
        XCTAssertEqual(
            SubShoutError.daemonResponse(code: "x", message: "y"),
            SubShoutError.daemonResponse(code: "x", message: "y")
        )
        XCTAssertNotEqual(
            SubShoutError.daemonResponse(code: "x", message: "y"),
            SubShoutError.daemonResponse(code: "x", message: "z")
        )
    }
}
