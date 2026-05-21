import AppKit
import SwiftUI

/// SwiftUI Settings UI.  Tabs: Hotkey, Model, Sounds, About.
struct SettingsView: View {
    @EnvironmentObject var controller: RecordingController
    @ObservedObject private var settings: AppSettings

    init() {
        self._settings = ObservedObject(wrappedValue: AppSettings.shared)
    }

    var body: some View {
        TabView {
            HotkeyTab().tabItem { Label("Hotkey", systemImage: "command") }
                .environmentObject(settings)
                .environmentObject(controller)
            ModelTab().tabItem { Label("Model", systemImage: "cpu") }
                .environmentObject(settings)
            SoundsTab().tabItem { Label("Sounds", systemImage: "speaker.wave.2") }
                .environmentObject(settings)
            AboutTab().tabItem { Label("About", systemImage: "info.circle") }
                .environmentObject(settings)
        }
        .frame(width: 480, height: 360)
        .padding(20)
        .onAppear {
            // SMAppService state can drift if the user toggles it from
            // System Settings while we're running.  Resync when shown.
            settings.refreshLaunchAtLogin()
        }
    }
}

// MARK: - Hotkey

private struct HotkeyTab: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var controller: RecordingController
    @State private var recording = false

    enum TapCount: Hashable { case single, double }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Trigger").font(.headline)
            HotkeyRecorderField(spec: $settings.trigger, recording: $recording)

            // Tap-count picker only makes sense for bare-modifier bindings.
            // For key combos we hide it entirely to avoid noise.
            if settings.trigger.isModifierTap {
                Picker("Tap count", selection: tapCountBinding) {
                    Text("Single tap").tag(TapCount.single)
                    Text("Double tap").tag(TapCount.double)
                }
                .pickerStyle(.segmented)

                Text(tapCountHelp)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Picker("Mode", selection: $settings.triggerMode) {
                ForEach(AppSettings.TriggerMode.allCases) { m in
                    Text(m.label).tag(m)
                }
            }
            .pickerStyle(.segmented)

            Text(modeHelpText)
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()

            HStack {
                Button("Re-install hotkey listener") {
                    controller.reinstallHotkey()
                }
                .help("Use this after granting Accessibility permission for the first time.")
                Spacer()
            }
        }
    }

    /// Read the current spec's tap-count, write a new spec preserving the
    /// keyCode but with the chosen tap count.  Disabled (.double fallback)
    /// when the binding isn't a modifier-tap.
    private var tapCountBinding: Binding<TapCount> {
        Binding(
            get: {
                switch settings.trigger {
                case .modifierSingleTap: return .single
                case .modifierDoubleTap: return .double
                case .keyCombo: return .double
                }
            },
            set: { newValue in
                guard let kc = settings.trigger.modifierKeyCode else { return }
                settings.trigger = (newValue == .single)
                    ? .modifierSingleTap(keyCode: kc)
                    : .modifierDoubleTap(keyCode: kc)
            }
        )
    }

    private var tapCountHelp: String {
        // Surface the false-positive shape so the user knows what they're
        // getting into when picking single-tap.
        switch tapCountBinding.wrappedValue {
        case .single:
            return "Fires on a clean press/release with nothing else pressed during the hold (no other keys, no clicks). Combos like ⌥+e or ⌥+click won't trigger."
        case .double:
            return "Fires on the second tap within 300ms. Safer against accidental triggering."
        }
    }

    private var modeHelpText: String {
        switch settings.triggerMode {
        case .toggle:
            return "Press once to start, again to stop. Recommended for most uses."
        case .holdToTalk:
            return "Hold to record, release to transcribe. Releases under 150ms are ignored."
        }
    }
}

/// Lets the user click into a field and press their desired hotkey.
///
/// Two capture flows, automatically chosen:
/// * If the user presses *only* a modifier (Option, Shift, Control, or
///   Command) and then releases without hitting any other key, we record
///   it as a modifier-tap binding.  We **preserve the current tap count**
///   if the field already held a modifier-tap binding — so changing only
///   the key doesn't reset the user's single/double choice.  Fresh
///   bindings (coming from a key-combo) default to double-tap.
/// * Otherwise the first non-modifier keyDown becomes a `keyCombo`.
///
/// The local NSEvent monitor is removed on disappear and on every commit
/// so we never leak it past the user's interaction window.
private struct HotkeyRecorderField: View {
    @Binding var spec: TriggerSpec
    @Binding var recording: Bool
    @State private var monitor: Any?
    @State private var modifierFirstSeen: UInt16?

    var body: some View {
        HStack {
            Text(spec.humanLabel)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(recording ? Color.accentColor.opacity(0.18) : Color.gray.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(recording ? Color.accentColor : Color.gray.opacity(0.4), lineWidth: 1)
                )
            Button(recording ? "Listening…" : "Click to record") {
                toggleRecording()
            }
            Button("Reset") {
                spec = .modifierDoubleTap(keyCode: 58)
            }
            .help("Restore default: double-tap left ⌥")
        }
        .onDisappear { stopRecording() }
    }

    private func toggleRecording() {
        if recording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        recording = true
        modifierFirstSeen = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            self.handle(event: event)
            return nil   // swallow
        }
    }

    private func stopRecording() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
        recording = false
        modifierFirstSeen = nil
    }

    private func handle(event: NSEvent) {
        switch event.type {
        case .keyDown:
            // Real key (with optional modifiers) → keyCombo.
            // Reject Fn (kVK_Function = 63) per TODO.md.
            let kc = event.keyCode
            if kc == 63 {
                NSSound.beep()
                return
            }
            let mods = event.modifierFlags
                .intersection([.command, .shift, .option, .control])
                .rawValue
            spec = .keyCombo(keyCode: kc, modifiers: UInt64(mods))
            stopRecording()

        case .flagsChanged:
            // Modifier-only press.  Commit on release of the same key
            // we first saw — naive but adequate for a binding UI.
            let kc = event.keyCode
            let isPress = !event.modifierFlags
                .intersection([.command, .shift, .option, .control, .capsLock])
                .isEmpty
            if isPress {
                if modifierFirstSeen == nil {
                    modifierFirstSeen = kc
                }
            } else if let first = modifierFirstSeen, first == kc {
                // Preserve current tap-count if we're already a
                // modifier-tap binding; default to double otherwise.
                let wasSingle: Bool = {
                    if case .modifierSingleTap = spec { return true }
                    return false
                }()
                spec = wasSingle
                    ? .modifierSingleTap(keyCode: first)
                    : .modifierDoubleTap(keyCode: first)
                stopRecording()
            }

        default:
            break
        }
    }
}

// MARK: - Model

private struct ModelTab: View {
    @EnvironmentObject var settings: AppSettings

    private let curated: [(id: String, label: String)] = [
        ("mlx-community/parakeet-tdt-0.6b-v2",
         "parakeet-tdt-0.6b-v2 — recommended (English, ~600M)"),
        ("mlx-community/parakeet-tdt-0.6b-v3",
         "parakeet-tdt-0.6b-v3 — multilingual ~600M"),
        ("mlx-community/parakeet-tdt-1.1b",
         "parakeet-tdt-1.1b — larger English ~1.1B"),
        ("mlx-community/parakeet-rnnt-1.1b",
         "parakeet-rnnt-1.1b — RNN-T English ~1.1B"),
        ("mlx-community/parakeet-tdt_ctc-110m",
         "parakeet-tdt_ctc-110m — tiny, fastest"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("ASR Model").font(.headline)
            Picker("", selection: $settings.modelID) {
                ForEach(curated, id: \.id) { item in
                    Text(item.label).tag(item.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            Text("Changing the model restarts the daemon. Models are downloaded the first time they're used.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()
        }
    }
}

// MARK: - Sounds

private struct SoundsTab: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle("Play start/stop sounds", isOn: $settings.soundsEnabled)
            Text("Plays Tink.aiff when recording starts and Pop.aiff when it ends.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

// MARK: - About

private struct AboutTab: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("subshout").font(.title2).bold()
            Text("Local-first dictation for macOS.")
                .foregroundStyle(.secondary)
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                .font(.callout)

            Divider().padding(.vertical, 4)

            Toggle("Launch subshout at login", isOn: $settings.launchAtLogin)
            Text("Registers subshout as a Login Item via SMAppService. You can also toggle this in System Settings → General → Login Items.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()
            Text("Logs: ~/Library/Logs/subshout/daemon.log")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}
