import AppKit
import XCTest
@testable import SubShout

final class PillPlacementTests: XCTestCase {
    private let windowSize = NSSize(width: 220, height: 60)

    func testPlacementReappliesSameRelativePositionOnDifferentScreen() {
        let sourceVisibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let targetVisibleFrame = NSRect(x: 1440, y: 0, width: 1920, height: 1080)
        let sourceOrigin = NSPoint(x: 970, y: 210)
        let sourceFrame = NSRect(origin: sourceOrigin, size: windowSize)

        let placement = PillPlacement(
            windowFrame: sourceFrame,
            screenVisibleFrame: sourceVisibleFrame
        )
        let targetOrigin = placement.origin(
            windowSize: windowSize,
            screenVisibleFrame: targetVisibleFrame
        )

        XCTAssertEqual(
            normalizedX(targetOrigin, in: targetVisibleFrame),
            placement.xRatio,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            normalizedY(targetOrigin, in: targetVisibleFrame),
            placement.yRatio,
            accuracy: 0.0001
        )
    }

    func testPlacementClampsDraggedFrameToVisibleScreenBounds() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let offscreenFrame = NSRect(x: -80, y: 920, width: 220, height: 60)

        let placement = PillPlacement(
            windowFrame: offscreenFrame,
            screenVisibleFrame: visibleFrame
        )
        let origin = placement.origin(
            windowSize: windowSize,
            screenVisibleFrame: visibleFrame
        )

        XCTAssertEqual(origin.x, visibleFrame.minX, accuracy: 0.0001)
        XCTAssertEqual(origin.y, visibleFrame.maxY - windowSize.height, accuracy: 0.0001)
    }

    func testClampedOriginHandlesScreensSmallerThanThePill() {
        let tinyVisibleFrame = NSRect(x: 100, y: 200, width: 120, height: 40)
        let origin = PillPlacement.clampedOrigin(
            NSPoint(x: 999, y: 999),
            windowSize: windowSize,
            screenVisibleFrame: tinyVisibleFrame
        )

        XCTAssertEqual(origin.x, tinyVisibleFrame.minX, accuracy: 0.0001)
        XCTAssertEqual(origin.y, tinyVisibleFrame.minY, accuracy: 0.0001)
    }

    private func normalizedX(_ origin: NSPoint, in visibleFrame: NSRect) -> CGFloat {
        (origin.x - visibleFrame.minX) / (visibleFrame.width - windowSize.width)
    }

    private func normalizedY(_ origin: NSPoint, in visibleFrame: NSRect) -> CGFloat {
        (origin.y - visibleFrame.minY) / (visibleFrame.height - windowSize.height)
    }
}
