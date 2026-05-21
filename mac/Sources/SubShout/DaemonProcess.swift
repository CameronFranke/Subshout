import Foundation
import OSLog

/// Owns the lifecycle of the bundled `shout-daemon` Python process.
///
/// Resolution order for the daemon executable:
///   1. `SHOUT_DAEMON_CMD` env var — used during dev.  Should point at a
///      shell script that runs `uv run shout-daemon` from the repo root.
///   2. `subshout.app/Contents/Resources/shout-daemon/bin/shout-daemon` —
///      the bundled standalone Python env produced by scripts/build-daemon-bundle.sh
///      script.
///
/// We also own the canonical paths for the socket and the log file (under
/// `~/Library/Application Support/subshout/` and `~/Library/Logs/subshout/`).
final class DaemonProcess {
    private let log = Logger(subsystem: "com.cameronfranke.SubShout", category: "DaemonProcess")

    let socketURL: URL
    let logFileURL: URL
    private(set) var process: Process?

    /// `true` once `launch()` returns successfully and the process is alive.
    var isRunning: Bool { process?.isRunning == true }

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("subshout", isDirectory: true)

        let logsDir = FileManager.default.urls(
            for: .libraryDirectory, in: .userDomainMask
        ).first!.appendingPathComponent("Logs/subshout", isDirectory: true)

        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        self.socketURL = appSupport.appendingPathComponent("daemon.sock")
        self.logFileURL = logsDir.appendingPathComponent("daemon.log")
    }

    func launch(preloadModel: String? = nil) throws {
        if let p = process, p.isRunning {
            log.warning("daemon already running with pid \(p.processIdentifier)")
            return
        }
        let (executable, baseArgs) = try Self.resolveExecutable()
        var args = baseArgs
        args.append(contentsOf: [
            "--socket", socketURL.path,
            "--log-file", logFileURL.path,
        ])
        if let m = preloadModel {
            args.append(contentsOf: ["--preload", m])
        }

        let p = Process()
        p.executableURL = executable
        p.arguments = args
        // Daemon writes its own logs; null out our pipes so the child doesn't
        // block on a backed-up parent stdout/err pipe.
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            self?.log.warning("daemon exited with status \(proc.terminationStatus)")
        }

        log.info("launching daemon: \(executable.path, privacy: .public) \(args.joined(separator: " "), privacy: .public)")
        try p.run()
        self.process = p
    }

    func terminate() {
        guard let p = process else { return }
        if p.isRunning {
            p.terminate()
        }
        process = nil
    }

    deinit { terminate() }

    // MARK: - Executable resolution

    private static func resolveExecutable() throws -> (URL, [String]) {
        if let override = ProcessInfo.processInfo.environment["SHOUT_DAEMON_CMD"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw SubShoutError.daemonNotFound("SHOUT_DAEMON_CMD points at \(url.path), which is not executable")
            }
            return (url, [])
        }
        let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("shout-daemon/bin/shout-daemon")
        if let b = bundled, FileManager.default.isExecutableFile(atPath: b.path) {
            return (b, [])
        }
        throw SubShoutError.daemonNotFound(
            "set SHOUT_DAEMON_CMD (dev) or bundle a Python env at subshout.app/Contents/Resources/shout-daemon/ (release)"
        )
    }
}
