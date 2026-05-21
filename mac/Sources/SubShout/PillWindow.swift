import AppKit
import Combine
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
/// `mouseDownCanMoveWindow`.  The window's origin is persisted to
/// `UserDefaults` and restored on next show.  If the saved position is
/// off all current screens (monitor unplugged, resolution change), we
/// fall back to default bottom-center placement.
final class PillWindowController: NSObject {
    private static let originDefaultsKey = "subshout.pillOrigin"

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
        UserDefaults.standard.removeObject(forKey: Self.originDefaultsKey)
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
        w.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary,
        ]
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
        if let pos = loadSavedPosition(),
           Self.isOnAnyScreen(point: pos, size: w.frame.size)
        {
            w.setFrameOrigin(pos)
            return
        }
        positionAtBottomCenter(w)
    }

    private func positionAtBottomCenter(_ w: NSWindow) {
        guard let screen = NSScreen.main else { return }
        let v = screen.visibleFrame
        let x = v.midX - w.frame.width / 2
        let y = v.minY + 80
        w.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func savePosition(_ w: NSWindow) {
        let origin = w.frame.origin
        UserDefaults.standard.set(
            ["x": Double(origin.x), "y": Double(origin.y)],
            forKey: Self.originDefaultsKey
        )
    }

    private func loadSavedPosition() -> NSPoint? {
        guard let dict = UserDefaults.standard.dictionary(forKey: Self.originDefaultsKey),
              let x = dict["x"] as? Double,
              let y = dict["y"] as? Double
        else { return nil }
        return NSPoint(x: x, y: y)
    }

    private static func isOnAnyScreen(point: NSPoint, size: NSSize) -> Bool {
        let rect = NSRect(origin: point, size: size)
        for screen in NSScreen.screens {
            if screen.frame.intersection(rect).equalTo(rect) {
                return true
            }
        }
        return false
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
