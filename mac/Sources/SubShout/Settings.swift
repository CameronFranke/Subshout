import AppKit
import Combine
import CoreGraphics
import Foundation

/// Persisted user settings.  Backed by `UserDefaults`; published so SwiftUI
/// can observe.  Mutations write through immediately.
///
/// Hotkey serialization: the `HotkeyManager.Trigger` enum embeds non-
/// `Codable` `CGEventFlags`, so we keep a parallel `TriggerSpec` here that
/// is `Codable` and bridge it via `.asTrigger` / `.init(_:)`.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    enum TriggerMode: String, CaseIterable, Identifiable {
        case toggle, holdToTalk
        var id: String { rawValue }
        var label: String {
            switch self {
            case .toggle: return "Toggle"
            case .holdToTalk: return "Hold to talk"
            }
        }
    }

    @Published var modelID: String {
        didSet { defaults.set(modelID, forKey: Keys.modelID) }
    }

    @Published var triggerMode: TriggerMode {
        didSet { defaults.set(triggerMode.rawValue, forKey: Keys.triggerMode) }
    }

    @Published var soundsEnabled: Bool {
        didSet { defaults.set(soundsEnabled, forKey: Keys.soundsEnabled) }
    }

    @Published var trigger: TriggerSpec {
        didSet { TriggerSpec.persist(trigger, to: defaults, key: Keys.trigger) }
    }

    /// Mirror of the SMAppService login-item registration state, exposed
    /// so the Settings UI can drive a toggle.  Reads through to
    /// `LoginItem.isRegistered` lazily; writes call `register()` /
    /// `unregister()` and re-publish.
    @Published var launchAtLogin: Bool {
        didSet {
            // Avoid re-entering when the LoginItem code itself triggered the
            // change (e.g. first-launch auto-register).
            guard launchAtLogin != LoginItem.isRegistered else { return }
            if launchAtLogin {
                LoginItem.register()
            } else {
                LoginItem.unregister()
            }
        }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let modelID = "subshout.modelID"
        static let triggerMode = "subshout.triggerMode"
        static let soundsEnabled = "subshout.soundsEnabled"
        static let trigger = "subshout.trigger"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.modelID = defaults.string(forKey: Keys.modelID)
            ?? "mlx-community/parakeet-tdt-0.6b-v2"
        self.triggerMode = TriggerMode(
            rawValue: defaults.string(forKey: Keys.triggerMode) ?? ""
        ) ?? .toggle
        if defaults.object(forKey: Keys.soundsEnabled) == nil {
            self.soundsEnabled = true
        } else {
            self.soundsEnabled = defaults.bool(forKey: Keys.soundsEnabled)
        }
        self.trigger = TriggerSpec.load(from: defaults, key: Keys.trigger)
            ?? .modifierDoubleTap(keyCode: 58)  // left option
        self.launchAtLogin = LoginItem.isRegistered
    }

    /// Re-read the live registration state from SMAppService.  Useful
    /// after a first-launch auto-register or when the user flips the
    /// system-level toggle while Settings is open.
    func refreshLaunchAtLogin() {
        let live = LoginItem.isRegistered
        if launchAtLogin != live {
            launchAtLogin = live
        }
    }
}

// MARK: - TriggerSpec

enum TriggerSpec: Codable, Equatable {
    case modifierSingleTap(keyCode: UInt16)
    case modifierDoubleTap(keyCode: UInt16)
    case keyCombo(keyCode: UInt16, modifiers: UInt64)

    var humanLabel: String {
        switch self {
        case .modifierSingleTap(let kc):
            return "Tap \(KeyName.modifier(for: kc))"
        case .modifierDoubleTap(let kc):
            return "Double-tap \(KeyName.modifier(for: kc))"
        case .keyCombo(let kc, let mods):
            return "\(KeyName.modifierFlags(mods))\(KeyName.regular(for: kc))"
        }
    }

    /// True iff the binding is one of the bare-modifier-tap kinds (which
    /// is the only context where the "Single | Double" picker applies).
    var isModifierTap: Bool {
        switch self {
        case .modifierSingleTap, .modifierDoubleTap: return true
        case .keyCombo: return false
        }
    }

    /// Non-nil only for modifier-tap bindings.  Lets the Settings picker
    /// flip tap-count without re-prompting for a key.
    var modifierKeyCode: UInt16? {
        switch self {
        case .modifierSingleTap(let kc), .modifierDoubleTap(let kc): return kc
        case .keyCombo: return nil
        }
    }

    var asTrigger: HotkeyManager.Trigger {
        switch self {
        case .modifierSingleTap(let kc):
            return .modifierSingleTap(keyCode: CGKeyCode(kc))
        case .modifierDoubleTap(let kc):
            return .modifierDoubleTap(keyCode: CGKeyCode(kc))
        case .keyCombo(let kc, let mods):
            return .keyCombo(keyCode: CGKeyCode(kc), modifiers: CGEventFlags(rawValue: mods))
        }
    }

    init(_ trigger: HotkeyManager.Trigger) {
        switch trigger {
        case .modifierSingleTap(let kc):
            self = .modifierSingleTap(keyCode: UInt16(kc))
        case .modifierDoubleTap(let kc):
            self = .modifierDoubleTap(keyCode: UInt16(kc))
        case .keyCombo(let kc, let mods):
            self = .keyCombo(keyCode: UInt16(kc), modifiers: mods.rawValue)
        }
    }

    static func load(from defaults: UserDefaults, key: String) -> TriggerSpec? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(TriggerSpec.self, from: data)
    }

    static func persist(_ spec: TriggerSpec, to defaults: UserDefaults, key: String) {
        if let data = try? JSONEncoder().encode(spec) {
            defaults.set(data, forKey: key)
        }
    }
}

// MARK: - Key naming
//
// Just enough mapping to render readable labels in the Settings UI.  Falls
// back to `Key 0xNN` for anything we don't recognize — that's fine, the
// user can rebind from the UI.

enum KeyName {
    static func modifier(for keyCode: UInt16) -> String {
        switch keyCode {
        case 54: return "Right ⌘"
        case 55: return "Left ⌘"
        case 56: return "Left ⇧"
        case 57: return "Caps Lock"
        case 58: return "Left ⌥"
        case 59: return "Left ⌃"
        case 60: return "Right ⇧"
        case 61: return "Right ⌥"
        case 62: return "Right ⌃"
        case 63: return "Fn"
        default: return "Key 0x\(String(keyCode, radix: 16))"
        }
    }

    /// CGEventFlags raw bits we care about:
    ///   maskShift     = 0x020000
    ///   maskControl   = 0x040000
    ///   maskAlternate = 0x080000
    ///   maskCommand   = 0x100000
    static func modifierFlags(_ flags: UInt64) -> String {
        var s = ""
        if flags & 0x040000 != 0 { s += "⌃" }
        if flags & 0x080000 != 0 { s += "⌥" }
        if flags & 0x020000 != 0 { s += "⇧" }
        if flags & 0x100000 != 0 { s += "⌘" }
        return s
    }

    static func regular(for keyCode: UInt16) -> String {
        switch keyCode {
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 36: return "Return"
        case 48: return "Tab"
        case 49: return "Space"
        case 51: return "Delete"
        case 53: return "Esc"
        case 0x7B: return "←"
        case 0x7C: return "→"
        case 0x7D: return "↓"
        case 0x7E: return "↑"
        case 0x69: return "F13"
        case 0x6B: return "F14"
        case 0x71: return "F15"
        default: return "Key 0x\(String(keyCode, radix: 16))"
        }
    }
}
