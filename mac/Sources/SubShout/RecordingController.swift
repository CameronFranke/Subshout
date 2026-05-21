import AppKit
import Combine
import Foundation
import OSLog

/// Top-level orchestrator.  Owns the daemon, the audio recorder, the pill,
/// the hotkey, and the (small) state machine that ties them together.
///
///     idle ── hotkey ──▶ recording ── hotkey/release ──▶ transcribing ──▶ idle
///
/// All state mutations happen on the main queue.  Background work (audio,
/// daemon RPCs) hops back to main before touching the state.
@MainActor
final class RecordingController: ObservableObject {
    private let log = Logger(subsystem: "com.cameronfranke.SubShout", category: "RecordingController")

    enum State: Equatable {
        case idle
        case startingDaemon
        case recording
        case transcribing
        case error(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastTranscript: String = ""
    @Published private(set) var daemonReady: Bool = false

    /// True once the global hotkey tap is alive and the required macOS privacy
    /// grants (Accessibility + Input Monitoring) are present for this binary.
    /// When false the menu surfaces clear permission actions.
    @Published private(set) var hotkeyActive: Bool = false

    let settings: AppSettings

    private let daemonProcess = DaemonProcess()
    private let daemonClient = DaemonClient()
    private let recorder = AudioRecorder()
    let pill = PillWindowController()         // exposed so menu can "Reset position"
    private let hotkeys = HotkeyManager()
    private var startupTask: Task<Void, Never>?
    private var axPollTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    /// Hold-to-talk safety: if the user releases the trigger before this
    /// many ms, throw the take away.  Catches accidental taps.
    private static let minHoldDurationMS: UInt64 = 150
    private var recordingStartedAt: Date?

    init(settings: AppSettings = .shared) {
        self.settings = settings

        // PillWindowController.setBands itself dispatches to main, so it
        // is safe to call from the audio thread.
        recorder.bandsHandler = { [pill] bands in
            pill.setBands(bands)
        }
        hotkeys.trigger = settings.trigger.asTrigger
        hotkeys.onActivate = { [weak self] in
            Task { @MainActor in self?.handleActivate() }
        }
        hotkeys.onDeactivate = { [weak self] in
            Task { @MainActor in self?.handleDeactivate() }
        }
    }

    // MARK: - Lifecycle (called from AppDelegate)

    func start() {
        startupTask = Task { [weak self] in
            await self?.startDaemonAndPoll()
        }
        installHotkeyOrPoll()
        observeSettings()
    }

    func stop() {
        startupTask?.cancel()
        axPollTask?.cancel()
        hotkeys.stop()
        Task { [client = daemonClient] in
            try? await client.shutdown()
            client.disconnect()
        }
        daemonProcess.terminate()
    }

    // MARK: - Public actions (Menu / Settings)

    func toggleRecord() {
        switch state {
        case .idle: beginRecording()
        case .recording: endRecording()
        default: break
        }
    }

    func cancelRecording() {
        guard state == .recording else { return }
        _ = recorder.stopAndDrain()
        pill.hide()
        state = .idle
        recordingStartedAt = nil
    }

    /// User explicitly asked to (re-)install the hotkey listener.
    /// Force-prompts required hotkey permissions if not granted.
    func reinstallHotkey() {
        hotkeys.stop()
        hotkeyActive = false
        let granted = HotkeyManager.ensureRequiredPermissions(prompt: true)
        if granted {
            installHotkey()
        }
        if !hotkeyActive {
            startAXPolling()
        }
    }

    /// Open the Accessibility pane in System Settings directly.
    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// Open the Input Monitoring pane in System Settings directly.
    func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }

    /// Stop the daemon, relaunch it, reconnect.  Useful when something
    /// has wedged (e.g. model swap).
    func restartDaemon() {
        startupTask?.cancel()
        daemonClient.disconnect()
        daemonProcess.terminate()
        daemonReady = false
        state = .startingDaemon
        startupTask = Task { [weak self] in
            // Small delay to let the OS fully release the previous socket.
            try? await Task.sleep(nanoseconds: 300_000_000)
            await self?.startDaemonAndPoll()
        }
    }

    // MARK: - Hotkey handlers

    private func handleActivate() {
        switch settings.triggerMode {
        case .toggle:
            toggleRecord()
        case .holdToTalk:
            if state == .idle { beginRecording() }
        }
    }

    private func handleDeactivate() {
        guard settings.triggerMode == .holdToTalk else { return }
        guard state == .recording else { return }
        if let started = recordingStartedAt {
            let elapsedMS = UInt64(Date().timeIntervalSince(started) * 1000)
            if elapsedMS < Self.minHoldDurationMS {
                log.info("hold cancelled: \(elapsedMS)ms < \(Self.minHoldDurationMS)ms")
                cancelRecording()
                return
            }
        }
        endRecording()
    }

    // MARK: - State machine

    private func beginRecording() {
        guard daemonReady else {
            log.warning("ignoring activate: daemon not ready")
            NSSound.beep()
            return
        }
        Task { [weak self] in
            let granted = await AudioRecorder.ensureMicPermission()
            guard let self = self else { return }
            await MainActor.run {
                guard granted else {
                    self.state = .error(SubShoutError.microphoneDenied.errorDescription ?? "")
                    NSSound.beep()
                    return
                }
                do {
                    try self.recorder.start()
                    self.recordingStartedAt = Date()
                    self.state = .recording
                    self.pill.show()
                    if self.settings.soundsEnabled { Sounds.start() }
                } catch {
                    self.state = .error(error.localizedDescription)
                    self.pill.hide()
                    NSSound.beep()
                }
            }
        }
    }

    private func endRecording() {
        guard state == .recording else { return }
        let pcm = recorder.stopAndDrain()
        recordingStartedAt = nil
        if settings.soundsEnabled { Sounds.stop() }
        pill.hide()
        state = .transcribing

        // Empty PCM → skip the daemon round-trip.  Cheap defense against
        // stop-immediately-after-start accidents.
        guard !pcm.isEmpty else {
            state = .idle
            return
        }

        // Snapshot whether *we* are the front app at the moment the user
        // stopped recording.  If yes, only copy — we don't want ⌘V to land
        // in our own Settings window.
        let weAreFront = NSApp.isActive

        Task { [weak self, client = daemonClient] in
            do {
                let result = try await client.transcribe(pcm: pcm, sampleRate: 16_000)
                await MainActor.run {
                    guard let self = self else { return }
                    self.lastTranscript = result.text
                    self.state = .idle
                    if !result.text.isEmpty {
                        if weAreFront {
                            Pasteboard.copy(result.text)
                            self.log.info("active app is subshout; copy-only")
                        } else {
                            Pasteboard.copyAndPaste(result.text)
                        }
                    }
                    self.log.info(
                        "transcribed \(result.audioSeconds, privacy: .public)s in \(result.transcribeSeconds, privacy: .public)s"
                    )
                }
            } catch {
                await MainActor.run {
                    self?.state = .error(error.localizedDescription)
                    NSSound.beep()
                }
            }
        }
    }

    // MARK: - Daemon

    private func startDaemonAndPoll() async {
        await MainActor.run { self.state = .startingDaemon }
        do {
            try daemonProcess.launch(preloadModel: settings.modelID)
            try await waitForSocket(at: daemonProcess.socketURL.path, timeoutSeconds: 30)
            try await daemonClient.connect(socketPath: daemonProcess.socketURL.path)
        } catch {
            await MainActor.run {
                self.daemonReady = false
                self.state = .error("Daemon: \(error.localizedDescription)")
            }
            return
        }

        // Poll status until ready.  No hard cap — first-run weight
        // download can take a while.
        while !Task.isCancelled {
            do {
                let status = try await daemonClient.status()
                if status.ready {
                    await MainActor.run {
                        self.daemonReady = true
                        self.state = .idle
                    }
                    return
                }
            } catch {
                await MainActor.run {
                    self.daemonReady = false
                    self.state = .error("Daemon: \(error.localizedDescription)")
                }
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func waitForSocket(at path: String, timeoutSeconds: Int) async throws {
        let fm = FileManager.default
        for _ in 0..<(timeoutSeconds * 10) {
            if Task.isCancelled { throw CancellationError() }
            if fm.fileExists(atPath: path) { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw SubShoutError.daemonNotFound("daemon socket never appeared at \(path)")
    }

    // MARK: - Hotkey install + AX polling
    //
    // First-launch flow:
    //   1. Try to install the tap. If Accessibility + Input Monitoring are
    //      already trusted, this works.
    //   2. If not trusted, prompt (system dialogs appear once per binary) and
    //      start a background poll task that re-checks every 1.5s.
    //   3. As soon as both grants flip to trusted, install the tap and stop
    //      polling.
    //
    // The user never has to come back and click "Re-install" — they just
    // grant access in System Settings and the hotkey lights up on its own.

    private func installHotkeyOrPoll() {
        if HotkeyManager.ensureRequiredPermissions(prompt: false) {
            installHotkey()
            if hotkeyActive { return }
        }
        let key = "subshout.didNagAccessibility"
        if !UserDefaults.standard.bool(forKey: key) {
            _ = HotkeyManager.ensureRequiredPermissions(prompt: true)
            UserDefaults.standard.set(true, forKey: key)
        }
        log.warning("Accessibility/Input Monitoring not granted; polling for grants")
        startAXPolling()
    }

    private func installHotkey() {
        do {
            try hotkeys.start()
            hotkeyActive = true
            log.info("hotkey installed: \(self.settings.trigger.humanLabel, privacy: .public)")
        } catch {
            hotkeyActive = false
            log.error("hotkey start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func startAXPolling() {
        axPollTask?.cancel()
        axPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if Task.isCancelled { return }
                guard HotkeyManager.ensureRequiredPermissions(prompt: false) else { continue }
                let installed = await MainActor.run { () -> Bool in
                    guard let self = self else { return true }   // treat as "stop"
                    self.installHotkey()
                    return self.hotkeyActive
                }
                if installed { return }
            }
        }
    }

    // MARK: - Settings observation
    //
    // AppSettings @Published mutations come from SwiftUI bindings (main
    // thread), but Combine's contract doesn't actually guarantee that —
    // be explicit with `.receive(on:)` so we never end up touching
    // hotkeys/daemon from a random background thread.

    private func observeSettings() {
        settings.$trigger
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] spec in
                self?.hotkeys.trigger = spec.asTrigger
            }
            .store(in: &cancellables)

        settings.$modelID
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.restartDaemon()
            }
            .store(in: &cancellables)
    }
}
