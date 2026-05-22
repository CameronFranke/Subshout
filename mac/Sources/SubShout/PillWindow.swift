import AppKit
import Combine
import CoreGraphics
import SwiftUI

/// The floating recording-indicator pill.
///
/// Built as a borderless `NSWindow` at `.statusBar` level so it floats over
/// fullscreen apps and doesn't take focus.  The contents are SwiftUI: a
/// rounded capsule with a row of bars whose heights track the **live
/// frequency spectrum** of the mic input (low → high, left → right).
///
/// ## Movement
///
/// The pill accepts mouse events (`ignoresMouseEvents = false`) so the
/// user can drag it.  `NSHostingView` swallows the mousedown by default,
/// so we use a tiny subclass (`DragHostingView`) that returns `true` from
/// `mouseDownCanMoveWindow`.  The window's position is persisted as a
/// relative coordinate inside the current screen's visible frame, then
/// re-applied to whichever screen/Space is active the next time the pill
/// appears.  If the saved position is invalid, we fall back to default
/// bottom-center placement.
final class PillWindowController: NSObject {
    private static let placementDefaultsKey = "subshout.pillPlacement"
    private static let legacyOriginDefaultsKey = "subshout.pillOrigin"
    private static let activeWorkspaceCollectionBehavior: NSWindow.CollectionBehavior = [
        .moveToActiveSpace, .ignoresCycle, .fullScreenAuxiliary,
    ]

    private var window: NSWindow?
    private let levels = LevelStore()
    private var moveObserver: NSObjectProtocol?

    /// Push the latest spectrum frame.  Safe from any thread.  Length should
    /// match `LevelStore.barCount`; mismatched arrays are padded/trimmed.
    func setBands(_ bands: [Float]) {
        DispatchQueue.main.async { [levels] in levels.set(bands) }
    }

    func show() {
        ensureWindow()
        guard let w = window else { return }
        w.alphaValue = 0
        applyPosition(w)
        w.collectionBehavior = Self.activeWorkspaceCollectionBehavior
        w.orderFrontRegardless()
        levels.reset()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            w.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let w = window else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.20
            w.animator().alphaValue = 0
        }, completionHandler: { [weak w] in
            w?.orderOut(nil)
        })
    }

    /// Drop any saved position so the pill snaps back to default.
    func resetPosition() {
        UserDefaults.standard.removeObject(forKey: Self.placementDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.legacyOriginDefaultsKey)
        if let w = window { applyPosition(w) }
    }

    deinit {
        if let obs = moveObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    // MARK: - Build

    private func ensureWindow() {
        if window != nil { return }
        let view = PillView().environmentObject(levels)
        let host = DragHostingView(rootView: AnyView(view))

        let size = PillView.windowSize
        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = .statusBar
        // Avoid `canJoinAllSpaces` / `stationary`: for a hidden menu-bar-agent
        // window those can leave the next show tied to the Space/display where
        // AppKit first associated it.  `moveToActiveSpace` re-homes each show
        // into the currently active Space instead.
        w.collectionBehavior = Self.activeWorkspaceCollectionBehavior
        w.ignoresMouseEvents = false
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: w,
            queue: .main
        ) { [weak self] _ in
            self?.savePosition(w)
        }

        self.window = w
    }

    // MARK: - Position

    private func applyPosition(_ w: NSWindow) {
        guard let screen = Self.activeScreen() else { return }
        if let placement = loadSavedPlacement(windowSize: w.frame.size) {
            w.setFrameOrigin(
                placement.origin(
                    windowSize: w.frame.size,
                    screenVisibleFrame: screen.visibleFrame
                )
            )
            return
        }
        positionAtBottomCenter(w, on: screen)
    }

    private func positionAtBottomCenter(_ w: NSWindow, on screen: NSScreen) {
        let v = screen.visibleFrame
        let origin = NSPoint(x: v.midX - w.frame.width / 2, y: v.minY + 80)
        w.setFrameOrigin(
            PillPlacement.clampedOrigin(
                origin,
                windowSize: w.frame.size,
                screenVisibleFrame: v
            )
        )
    }

    private func savePosition(_ w: NSWindow) {
        guard let screen = Self.bestScreen(for: w.frame) else { return }
        let placement = PillPlacement(
            windowFrame: w.frame,
            screenVisibleFrame: screen.visibleFrame
        )
        UserDefaults.standard.set(
            [
                "xRatio": Double(placement.xRatio),
                "yRatio": Double(placement.yRatio),
            ],
            forKey: Self.placementDefaultsKey
        )
        UserDefaults.standard.removeObject(forKey: Self.legacyOriginDefaultsKey)
    }

    private func loadSavedPlacement(windowSize: NSSize) -> PillPlacement? {
        if let dict = UserDefaults.standard.dictionary(forKey: Self.placementDefaultsKey),
           let xRatio = Self.doubleValue(dict["xRatio"]),
           let yRatio = Self.doubleValue(dict["yRatio"])
        {
            return PillPlacement(xRatio: CGFloat(xRatio), yRatio: CGFloat(yRatio))
        }

        guard let legacyOrigin = loadLegacyOrigin() else { return nil }
        let legacyFrame = NSRect(origin: legacyOrigin, size: windowSize)
        guard let screen = Self.bestScreen(for: legacyFrame) else { return nil }
        return PillPlacement(windowFrame: legacyFrame, screenVisibleFrame: screen.visibleFrame)
    }

    private func loadLegacyOrigin() -> NSPoint? {
        guard let dict = UserDefaults.standard.dictionary(forKey: Self.legacyOriginDefaultsKey),
              let x = Self.doubleValue(dict["x"]),
              let y = Self.doubleValue(dict["y"])
        else { return nil }
        return NSPoint(x: x, y: y)
    }

    private static func activeScreen() -> NSScreen? {
        // Prefer the display containing the frontmost app's active window; that
        // is the display whose Space should receive the pill.  If the active app
        // has no normal window, fall back to the mouse because this menu-bar
        // agent usually has no key window of its own.
        if let frontmostScreen = frontmostApplicationScreen() {
            return frontmostScreen
        }
        if let mouseScreen = screen(containing: NSEvent.mouseLocation) {
            return mouseScreen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private static func frontmostApplicationScreen() -> NSScreen? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let windowInfo = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements],
                  kCGNullWindowID
              ) as? [[String: Any]]
        else { return nil }

        for info in windowInfo {
            guard let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  ownerPID == pid,
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict)
            else { continue }
            guard bounds.width > 1, bounds.height > 1 else { continue }
            if let screen = bestScreen(forWindowBounds: bounds) {
                return screen
            }
        }
        return nil
    }

    private static func bestScreen(forWindowBounds bounds: CGRect) -> NSScreen? {
        var bestScreen: NSScreen?
        var bestArea: CGFloat = 0
        for screen in NSScreen.screens {
            guard let screenNumber = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { continue }
            let displayBounds = CGDisplayBounds(CGDirectDisplayID(screenNumber.uint32Value))
            let overlap = displayBounds.intersection(bounds)
            guard !overlap.isNull, !overlap.isEmpty else { continue }
            let area = overlap.width * overlap.height
            if area > bestArea {
                bestArea = area
                bestScreen = screen
            }
        }
        return bestScreen
    }

    private static func bestScreen(for rect: NSRect) -> NSScreen? {
        var bestScreen: NSScreen?
        var bestArea: CGFloat = 0
        for screen in NSScreen.screens {
            let overlap = screen.frame.intersection(rect)
            guard !overlap.isNull, !overlap.isEmpty else { continue }
            let area = overlap.width * overlap.height
            if area > bestArea {
                bestArea = area
                bestScreen = screen
            }
        }
        if let bestScreen { return bestScreen }
        return screen(containing: rect.origin)
    }

    private static func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }
}

// MARK: - Relative pill placement

struct PillPlacement: Equatable {
    let xRatio: CGFloat
    let yRatio: CGFloat

    init(xRatio: CGFloat, yRatio: CGFloat) {
        self.xRatio = Self.clamp01(xRatio)
        self.yRatio = Self.clamp01(yRatio)
    }

    init(windowFrame: NSRect, screenVisibleFrame: NSRect) {
        let xTravel = max(screenVisibleFrame.width - windowFrame.width, 0)
        let yTravel = max(screenVisibleFrame.height - windowFrame.height, 0)
        let xRatio = xTravel > 0
            ? (windowFrame.minX - screenVisibleFrame.minX) / xTravel
            : 0.5
        let yRatio = yTravel > 0
            ? (windowFrame.minY - screenVisibleFrame.minY) / yTravel
            : 0
        self.init(xRatio: xRatio, yRatio: yRatio)
    }

    func origin(windowSize: NSSize, screenVisibleFrame: NSRect) -> NSPoint {
        let xTravel = max(screenVisibleFrame.width - windowSize.width, 0)
        let yTravel = max(screenVisibleFrame.height - windowSize.height, 0)
        let origin = NSPoint(
            x: screenVisibleFrame.minX + xTravel * xRatio,
            y: screenVisibleFrame.minY + yTravel * yRatio
        )
        return Self.clampedOrigin(
            origin,
            windowSize: windowSize,
            screenVisibleFrame: screenVisibleFrame
        )
    }

    static func clampedOrigin(
        _ origin: NSPoint,
        windowSize: NSSize,
        screenVisibleFrame: NSRect
    ) -> NSPoint {
        let maxX = max(screenVisibleFrame.minX, screenVisibleFrame.maxX - windowSize.width)
        let maxY = max(screenVisibleFrame.minY, screenVisibleFrame.maxY - windowSize.height)
        return NSPoint(
            x: clamp(origin.x, lowerBound: screenVisibleFrame.minX, upperBound: maxX),
            y: clamp(origin.y, lowerBound: screenVisibleFrame.minY, upperBound: maxY)
        )
    }

    private static func clamp01(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return clamp(value, lowerBound: 0, upperBound: 1)
    }

    private static func clamp(
        _ value: CGFloat,
        lowerBound: CGFloat,
        upperBound: CGFloat
    ) -> CGFloat {
        min(max(value, lowerBound), upperBound)
    }
}

// MARK: - Hosting view that lets the window be dragged

private final class DragHostingView: NSHostingView<AnyView> {
    override var mouseDownCanMoveWindow: Bool { true }
    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
    }
}

// MARK: - Level store

/// Holds the current spectrum frame.  Replaced wholesale on each push.
final class LevelStore: ObservableObject {
    static let barCount = FrequencyAnalyzer.bandCount   // currently 21
    @Published private(set) var bars: [Float] = Array(repeating: 0, count: barCount)

    func reset() {
        bars = Array(repeating: 0, count: Self.barCount)
    }

    func set(_ bands: [Float]) {
        if bands.count == Self.barCount {
            bars = bands
        } else if bands.count < Self.barCount {
            // Pad with zeros if the analyzer emitted fewer (shouldn't happen).
            bars = bands + Array(repeating: 0, count: Self.barCount - bands.count)
        } else {
            bars = Array(bands.prefix(Self.barCount))
        }
    }
}

// MARK: - SwiftUI view

struct PillView: View {
    // Keep the window exactly as large as the visible capsule. Anything outside
    // the capsule shape is true window transparency — no material, blur, or
    // shadow pass is allowed to paint a rectangular backing.
    static let pillSize = NSSize(width: 220, height: 60)
    static let windowSize = pillSize
    static let barMaxHeight: CGFloat = 40
    // Bar width MUST be a whole point.  Fractional widths (we tried 3.6)
    // get pixel-snapped per-bar and you end up with some 3px and some 4px
    // bars depending on each bar's cumulative left edge — looks bad on
    // @1x displays especially.  4pt is the closest clean integer to the
    // "20% wider than the original 3pt" target.
    // Total row width: 21*4 + 20*4 = 164pt, inside the 184pt interior
    // (220 pill − 2×18 horizontal padding) with ~10pt margin each side.
    static let barWidth: CGFloat = 4
    static let barSpacing: CGFloat = 4

    @EnvironmentObject var levels: LevelStore

    var body: some View {
        ZStack {
            glassBody
            bars
        }
        .frame(
            width: Self.pillSize.width,
            height: Self.pillSize.height,
            alignment: .center
        )
        .frame(
            width: Self.windowSize.width,
            height: Self.windowSize.height,
            alignment: .center
        )
        .background(Color.clear)
        // Tiny animation only — at our 62 Hz update rate (50% overlap FFTs)
        // we're feeding the display almost frame-for-frame, so a longer
        // ease here just adds visible smoothing on top of the analyzer's
        // EMA, which is what made it feel laggy before.
        .animation(.easeOut(duration: 0.03), value: levels.bars)
    }

    private var bars: some View {
        HStack(spacing: Self.barSpacing) {
            ForEach(Array(levels.bars.enumerated()), id: \.offset) { _, h in
                BarShape(height: CGFloat(h))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private var glassBody: some View {
        ZStack {
            CapsuleMaterial()

            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.30),
                            Color.white.opacity(0.12),
                            Color.black.opacity(0.12),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .blendMode(.overlay)

            Capsule(style: .continuous)
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.28), Color.clear],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: 210
                    )
                )
                .blendMode(.screen)

            Capsule(style: .continuous)
                .inset(by: 1)
                .strokeBorder(Color.black.opacity(0.14), lineWidth: 2)
                .blur(radius: 1)
                .offset(y: 1)

            Capsule(style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.62),
                            Color.white.opacity(0.18),
                            Color.black.opacity(0.20),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )

            Capsule(style: .continuous)
                .inset(by: 1.5)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
        }
        .clipShape(Capsule(style: .continuous))
    }

    private struct CapsuleMaterial: NSViewRepresentable {
        func makeNSView(context _: Context) -> CapsuleMaterialView {
            let view = CapsuleMaterialView()
            view.material = .hudWindow
            view.blendingMode = .behindWindow
            view.state = .active
            view.isEmphasized = true
            return view
        }

        func updateNSView(_ nsView: CapsuleMaterialView, context _: Context) {
            nsView.needsLayout = true
        }
    }

    private final class CapsuleMaterialView: NSVisualEffectView {
        private var cachedMaskSize: NSSize = .zero

        override var isOpaque: Bool { false }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureMask()
        }

        override func layout() {
            super.layout()
            configureMask()
        }

        private func configureMask() {
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.cornerRadius = bounds.height / 2
            layer?.cornerCurve = .continuous
            layer?.masksToBounds = true
            layer?.isOpaque = false

            guard bounds.width > 0, bounds.height > 0 else { return }
            if cachedMaskSize != bounds.size {
                cachedMaskSize = bounds.size
                maskImage = Self.makeCapsuleMask(size: bounds.size)
            }
        }

        private static func makeCapsuleMask(size: NSSize) -> NSImage {
            let image = NSImage(size: size)
            image.lockFocus()
            NSColor.white.setFill()
            NSBezierPath(
                roundedRect: NSRect(origin: .zero, size: size),
                xRadius: size.height / 2,
                yRadius: size.height / 2
            ).fill()
            image.unlockFocus()
            return image
        }
    }

    private struct BarShape: View {
        let height: CGFloat
        var body: some View {
            // Min height keeps the bar visible at silence.
            let h = max(0.06, min(1.0, height))
            return RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color.white.opacity(0.90))
                .shadow(color: .black.opacity(0.12), radius: 0.5, y: 0.5)
                .frame(width: PillView.barWidth, height: PillView.barMaxHeight * h)
        }
    }
}
