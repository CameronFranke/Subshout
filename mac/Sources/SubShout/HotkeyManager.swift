import AppKit
import ApplicationServices
import Foundation
import OSLog

/// Global hotkey listener built on `CGEventTap`.
///
/// Three trigger flavours:
///
/// * `.modifierSingleTap(keyCode)` — watch `flagsChanged` for that
///   specific keycode (left option = 58, right option = 61, …).  Fires on
///   the *release* of a "clean" press/release of the modifier alone.  A
///   cycle is "dirty" if any non-modifier key OR any mouse-down arrives
///   between the press and the release; this is what stops `⌥+e`,
///   `⌥+click`, `⌥+drag`, etc. from triggering.
///
/// * `.modifierDoubleTap(keyCode)` — same dirty-cycle rules, but fires
///   on the *second* clean press within 300ms of a clean release.
///
/// * `.keyCombo(keyCode, modifiers)` — match a `keyDown` with exactly the
///   listed modifiers (and nothing else).  Fires `onActivate` on keyDown
///   and `onDeactivate` on keyUp; the recording controller picks one or
///   both depending on toggle vs hold-to-talk mode.
///
/// We listen `.listenOnly` so we never swallow events.  In hold-to-talk
/// mode the user's chosen key still types its normal character — important
/// for picking combos that don't conflict with regular typing.
final class HotkeyManager {
    private let log = Logger(subsystem: "com.cameronfranke.SubShout", category: "HotkeyManager")

    enum Trigger: Equatable {
        case modifierSingleTap(keyCode: CGKeyCode)
        case modifierDoubleTap(keyCode: CGKeyCode)
        case keyCombo(keyCode: CGKeyCode, modifiers: CGEventFlags)

        static func == (lhs: Trigger, rhs: Trigger) -> Bool {
            switch (lhs, rhs) {
            case let (.modifierSingleTap(a), .modifierSingleTap(b)):
                return a == b
            case let (.modifierDoubleTap(a), .modifierDoubleTap(b)):
                return a == b
            case let (.keyCombo(a, ma), .keyCombo(b, mb)):
                return a == b && Self.relevantBits(ma) == Self.relevantBits(mb)
            default:
                return false
            }
        }

        static func relevantBits(_ f: CGEventFlags) -> UInt64 {
            let mask: CGEventFlags = [
                .maskCommand, .maskShift, .maskAlternate, .maskControl,
            ]
            return f.rawValue & mask.rawValue
        }
    }

    /// Default per TODO.md: double-tap left option (kVK_Option = 58).
    static let defaultTrigger: Trigger = .modifierDoubleTap(keyCode: 58)

    /// Window for the second tap of a double-tap, in seconds.
    static let doubleTapWindow: TimeInterval = 0.3

    var trigger: Trigger = HotkeyManager.defaultTrigger {
        didSet { reset() }
    }

    /// Fired on the main queue when the trigger activates.
    var onActivate: (() -> Void)?
    /// Fired on the main queue when the trigger key is released (combo
    /// mode only; tap modes never fire this).  Used by hold-to-talk.
    var onDeactivate: (() -> Void)?

    // MARK: - Permissions

    /// Returns true if Accessibility access is currently granted.  Pass
    /// `prompt: true` to show the system "open System Settings" dialog.
    @discardableResult
    static func ensureAccessibility(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    // MARK: - Lifecycle

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Modifier-tap state machine (shared by single- and double-tap modes).
    private var modIsDown = false
    private var lastCleanReleaseAt: TimeInterval = -1
    private var dirtyThisCycle = false

    func start() throws {
        if tap != nil { return }
        // Keyboard events for the main detection logic + mouse-down events
        // so that `⌥+click` correctly disqualifies a tap cycle.  We don't
        // need mouse-up/move/drag — just "did the user click while holding
        // the modifier."
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue)

        let info = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: HotkeyManager.tapCallback,
            userInfo: info
        ) else {
            throw SubShoutError.accessibilityDenied
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.tap = port
        self.runLoopSource = src
        log.info("hotkey tap installed")
    }

    func stop() {
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        if let t = tap {
            CGEvent.tapEnable(tap: t, enable: false)
        }
        tap = nil
        runLoopSource = nil
        reset()
    }

    private func reset() {
        modIsDown = false
        lastCleanReleaseAt = -1
        dirtyThisCycle = false
    }

    // MARK: - Event handling

    private static let tapCallback: CGEventTapCallBack = { _, type, event, info in
        if let info = info {
            let mgr = Unmanaged<HotkeyManager>.fromOpaque(info).takeUnretainedValue()
            // Restart the tap if the system disables it on us (e.g. our
            // process was paused under the debugger past the timeout).
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = mgr.tap { CGEvent.tapEnable(tap: t, enable: true) }
            } else {
                mgr.handle(type: type, event: event)
            }
        }
        return Unmanaged.passUnretained(event)
    }

    private func handle(type: CGEventType, event: CGEvent) {
        switch trigger {
        case .modifierSingleTap(let keyCode):
            handleModTap(type: type, event: event, target: keyCode, requireDouble: false)
        case .modifierDoubleTap(let keyCode):
            handleModTap(type: type, event: event, target: keyCode, requireDouble: true)
        case .keyCombo(let keyCode, let modifiers):
            handleCombo(type: type, event: event, keyCode: keyCode, modifiers: modifiers)
        }
    }

    /// Unified single/double-tap state machine for a bare modifier.
    private func handleModTap(
        type: CGEventType,
        event: CGEvent,
        target: CGKeyCode,
        requireDouble: Bool
    ) {
        switch type {
        case .keyDown, .keyUp,
             .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // Any non-modifier interaction during a held cycle disqualifies
            // it.  Critical for both single-tap (don't fire on ⌥+click) and
            // double-tap (don't conflate ⌥+click+⌥+click).
            if modIsDown { dirtyThisCycle = true }
            return

        case .flagsChanged:
            let kc = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            guard kc == target else {
                // A *different* modifier changed flags.  If we're holding
                // our target modifier, that means the user is composing
                // a multi-modifier combo — dirty.
                if modIsDown { dirtyThisCycle = true }
                return
            }
            // Each flagsChanged for keycode K toggles K's pressed state.
            let nowPressed = !modIsDown
            modIsDown = nowPressed
            let now = ProcessInfo.processInfo.systemUptime

            if nowPressed {
                if requireDouble,
                   !dirtyThisCycle,
                   lastCleanReleaseAt > 0,
                   (now - lastCleanReleaseAt) <= Self.doubleTapWindow
                {
                    // Second clean press within the window → fire double-tap.
                    lastCleanReleaseAt = -1
                    dirtyThisCycle = false
                    DispatchQueue.main.async { [weak self] in self?.onActivate?() }
                    return
                }
                // Otherwise: start fresh press cycle.
                dirtyThisCycle = false
            } else {
                // Release.  Two outcomes:
                //   single-tap mode + clean cycle  → fire now
                //   double-tap mode + clean cycle  → record release time
                if !dirtyThisCycle {
                    if requireDouble {
                        lastCleanReleaseAt = now
                    } else {
                        DispatchQueue.main.async { [weak self] in self?.onActivate?() }
                    }
                } else {
                    lastCleanReleaseAt = -1
                }
                dirtyThisCycle = false
            }

        default:
            return
        }
    }

    private func handleCombo(
        type: CGEventType,
        event: CGEvent,
        keyCode: CGKeyCode,
        modifiers: CGEventFlags
    ) {
        guard type == .keyDown || type == .keyUp else { return }
        let kc = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard kc == keyCode else { return }
        let evMods = Trigger.relevantBits(event.flags)
        let want = Trigger.relevantBits(modifiers)
        guard evMods == want else { return }

        // Suppress autorepeat keyDowns.
        let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if type == .keyDown {
            if isAutorepeat { return }
            DispatchQueue.main.async { [weak self] in self?.onActivate?() }
        } else {
            DispatchQueue.main.async { [weak self] in self?.onDeactivate?() }
        }
    }
}
