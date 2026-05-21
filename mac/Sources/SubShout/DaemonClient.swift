import Foundation
import OSLog

/// Async wrapper over the wire protocol.
///
/// All I/O is funnelled onto one serial dispatch queue so we never have two
/// requests in flight at once (the daemon is single-client and we'd corrupt
/// the framing).  The public surface is async functions; internally each
/// call hops onto the queue, sends a frame, blocks on `recv`, and resumes
/// the continuation with the parsed response.
final class DaemonClient {
    private let log = Logger(subsystem: "com.cameronfranke.SubShout", category: "DaemonClient")
    private let queue = DispatchQueue(label: "com.cameronfranke.SubShout.DaemonClient")
    private var socket = UnixSocketClient()
    private(set) var socketPath: String?

    struct Status {
        let ready: Bool
        let modelID: String?
        let version: String
    }

    struct TranscribeResult {
        let text: String
        let audioSeconds: Double
        let transcribeSeconds: Double
    }

    // MARK: - Connection

    func connect(socketPath: String) async throws {
        try await onQueue { [self] in
            socket.close()
            socket = UnixSocketClient()
            try socket.connect(to: socketPath)
            self.socketPath = socketPath
            log.info("connected to daemon at \(socketPath, privacy: .public)")
        }
    }

    func disconnect() {
        queue.sync {
            socket.close()
        }
    }

    var isConnected: Bool { socket.isConnected }

    // MARK: - High-level RPCs

    func status() async throws -> Status {
        let (h, _) = try await call(["type": "status"])
        return Status(
            ready: (h["ready"] as? Bool) ?? false,
            modelID: h["model_id"] as? String,
            version: (h["version"] as? String) ?? "?"
        )
    }

    func loadModel(_ modelID: String) async throws {
        _ = try await call(["type": "load_model", "model_id": modelID])
    }

    func transcribe(pcm: Data, sampleRate: Int = 16_000) async throws -> TranscribeResult {
        let (h, _) = try await call(
            ["type": "transcribe", "sample_rate": sampleRate],
            payload: pcm
        )
        return TranscribeResult(
            text: (h["text"] as? String) ?? "",
            audioSeconds: (h["audio_seconds"] as? Double) ?? 0,
            transcribeSeconds: (h["transcribe_seconds"] as? Double) ?? 0
        )
    }

    func shutdown() async throws {
        _ = try await call(["type": "shutdown"])
    }

    // MARK: - Plumbing

    /// Send one request frame and read one response frame.  Throws
    /// `SubShoutError.daemonResponse` for a non-`ok` response, and bubbles any
    /// I/O / framing errors otherwise.
    private func call(
        _ header: [String: Any],
        payload: Data = Data()
    ) async throws -> (header: [String: Any], payload: Data) {
        try await onQueue { [self] in
            try sendFrame(header: header, payload: payload)
            let (respHeader, respPayload) = try recvFrame()
            let type = (respHeader["type"] as? String) ?? ""
            if type == "error" {
                throw SubShoutError.daemonResponse(
                    code: (respHeader["code"] as? String) ?? "unknown",
                    message: (respHeader["message"] as? String) ?? "no message"
                )
            }
            if type != "ok" {
                throw SubShoutError.daemonProtocol("unexpected response type \(type.debugDescription)")
            }
            return (respHeader, respPayload)
        }
    }

    private func sendFrame(header: [String: Any], payload: Data) throws {
        let frame = try WireProtocol.encodeFrame(header: header, payload: payload)
        try socket.send(frame)
    }

    private func recvFrame() throws -> (header: [String: Any], payload: Data) {
        let lenBytes = try socket.recvExactly(4)
        let hlen = Int(WireProtocol.headerLength(fromPrefix: lenBytes))
        guard hlen > 0, hlen <= WireProtocol.maxHeaderBytes else {
            throw SubShoutError.daemonProtocol("bad header_len: \(hlen)")
        }
        let hRaw = try socket.recvExactly(hlen)
        guard let header = try JSONSerialization.jsonObject(with: hRaw) as? [String: Any] else {
            throw SubShoutError.daemonProtocol("response header is not a JSON object")
        }
        let payloadLen = (header["payload_len"] as? Int) ?? 0
        guard payloadLen >= 0, payloadLen <= WireProtocol.maxPayloadBytes else {
            throw SubShoutError.daemonProtocol("bad payload_len: \(payloadLen)")
        }
        let payload = payloadLen > 0 ? try socket.recvExactly(payloadLen) : Data()
        return (header, payload)
    }

    /// Run `body` on our serial queue and bridge to async/await.
    private func onQueue<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            queue.async {
                do {
                    cont.resume(returning: try body())
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}
