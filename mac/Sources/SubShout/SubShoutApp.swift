import AppKit
import SwiftUI

@main
struct SubShoutApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // Menu-bar entry point.  The label switches glyph based on state
        // so the user gets a glance-able recording indicator.
        MenuBarExtra {
            SubShoutMenu()
                .environmentObject(delegate.controller)
        } label: {
            MenuBarLabel()
                .environmentObject(delegate.controller)
        }

        // Standard SwiftUI Settings scene; hosts our SettingsView (4 tabs).
        Settings {
            SettingsView()
                .environmentObject(delegate.controller)
        }
    }
}

// MARK: - Menu-bar label

private struct MenuBarLabel: View {
    @EnvironmentObject var controller: RecordingController

    var body: some View {
        Image(systemName: glyph)
            .accessibilityLabel("subshout")
    }

    private var glyph: String {
        switch controller.state {
        case .recording: return "waveform"
        case .transcribing: return "ellipsis.circle"
        case .startingDaemon: return "hourglass"
        case .error: return "exclamationmark.triangle"
        case .idle: return controller.daemonReady ? "mic" : "mic.slash"
        }
    }
}

// MARK: - Menu contents

private struct SubShoutMenu: View {
    @EnvironmentObject var controller: RecordingController
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Group {
            Button(actionTitle) {
                controller.toggleRecord()
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(!canRecord)

            if case .error(let msg) = controller.state {
                Divider()
                Text("Error: \(msg)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()

            // SettingsLink is the canonical way to open the Settings scene
            // from a MenuBarExtra on macOS 14+.  On macOS 13 we fall back
            // to the (private but stable) `showPreferencesWindow:` selector.
            if #available(macOS 14, *) {
                SettingsLink {
                    Text("Settings…")
                }
                .keyboardShortcut(",", modifiers: [.command])
            } else {
                Button("Settings…") {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.sendAction(
                        Selector(("showPreferencesWindow:")), to: nil, from: nil
                    )
                }
                .keyboardShortcut(",", modifiers: [.command])
            }

            Divider()

            // Hotkey block: status text + actions.  When AX is denied we
            // show a one-click button to the right pane in System Settings.
            if controller.hotkeyActive {
                Text("Hotkey: \(settings.trigger.humanLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Hotkey: not active — Accessibility required")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button("Open Accessibility Settings") {
                    controller.openAccessibilitySettings()
                }
                Button("Re-install hotkey listener") {
                    controller.reinstallHotkey()
                }
            }

            Button("Reset pill position") {
                controller.pill.resetPosition()
            }
            .help("Move the recording indicator back to the bottom-center default.")

            Button("Restart daemon") {
                controller.restartDaemon()
            }
            .help("Stop and relaunch the Python daemon. Useful if it gets stuck.")

            Divider()

            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            Button("Quit subshout") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: [.command])
        }
    }

    private var canRecord: Bool {
        switch controller.state {
        case .idle: return controller.daemonReady
        case .recording: return true   // allow toggle off
        default: return false
        }
    }

    private var actionTitle: String {
        switch controller.state {
        case .idle: return controller.daemonReady ? "Start recording" : "Daemon not ready"
        case .recording: return "Stop recording"
        case .transcribing: return "Transcribing…"
        case .startingDaemon: return "Starting daemon…"
        case .error: return "Try again"
        }
    }

    private var statusText: String {
        switch controller.state {
        case .startingDaemon: return "Loading model…"
        case .idle:
            return controller.daemonReady ? "Ready" : "Daemon offline"
        case .recording: return "Recording"
        case .transcribing: return "Transcribing"
        case .error(let msg): return msg
        }
    }
}

// MARK: - App delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Created up-front, but we must wait until after launch to start the
    /// daemon (so `Bundle.main` is fully populated, etc.).
    let controller = RecordingController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
        // Register as a login item on first launch (default ON; user can
        // disable in Settings or System Settings → Login Items).
        LoginItem.registerOnFirstLaunchIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Menu-bar agent: closing the Settings window must NOT quit us.
        false
    }
}
