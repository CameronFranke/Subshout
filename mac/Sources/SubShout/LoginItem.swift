import Foundation
import OSLog
import ServiceManagement

/// Wrapper around `SMAppService.mainApp` for "launch subshout at login".
///
/// `SMAppService.mainApp` (macOS 13+) treats the running .app itself as
/// the login item — no separate launch-agent plist file, no helper
/// target.  The OS surfaces the toggle in System Settings → General →
/// Login Items, and the user can disable it there at any time; we don't
/// override their preference.
///
/// First-launch behavior (see TODO.md):
///   * On first launch we auto-register so users hit zero friction —
///     `install.sh`'s output documents this so it's not surprising.
///   * We stamp a UserDefaults key so we don't re-register if the user
///     later disabled it from System Settings.  Otherwise every cold
///     launch would silently re-enable login-at-startup, which is
///     exactly the behavior people complain about.
enum LoginItem {
    private static let log = Logger(subsystem: "com.cameronfranke.SubShout", category: "LoginItem")
    private static let firstLaunchKey = "subshout.didAutoRegisterLoginItem"

    /// Live registration state, read from `SMAppService`.  Use this for
    /// UI bindings — never cache it in a static var.
    static var isRegistered: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Register subshout to launch at login.  Logged on success/failure;
    /// never throws (the Settings toggle just won't move if the OS says
    /// no, which surfaces the failure to the user implicitly).
    static func register() {
        do {
            try SMAppService.mainApp.register()
            log.info("login item registered")
        } catch {
            log.error("register failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Unregister.  Same error policy as `register`.
    static func unregister() {
        do {
            try SMAppService.mainApp.unregister()
            log.info("login item unregistered")
        } catch {
            log.error("unregister failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Called once at app launch.  If we've never auto-registered before,
    /// register now and remember it.  No-op on every subsequent launch —
    /// the user's choice (whether they kept it on or turned it off) is
    /// what sticks.
    ///
    /// Skipped entirely when running outside a real .app bundle (e.g.
    /// `swift run` during dev) because SMAppService can't act on a
    /// bundleless process and would just log noise.
    static func registerOnFirstLaunchIfNeeded() {
        guard isRunningFromAppBundle() else {
            log.info("not in .app bundle; skipping first-launch login-item register")
            return
        }
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: firstLaunchKey) { return }

        if !isRegistered {
            register()
        }
        defaults.set(true, forKey: firstLaunchKey)
    }

    /// True if `Bundle.main` looks like a `.app` (vs `swift run` etc.).
    /// SMAppService only works in the bundled case.
    private static func isRunningFromAppBundle() -> Bool {
        let path = Bundle.main.bundlePath
        return path.hasSuffix(".app")
    }
}
