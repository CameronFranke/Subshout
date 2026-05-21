import Foundation

/// Pure-Swift helpers for the daemon wire protocol.
///
/// Frame layout (all integers big-endian):
///
///     +-------------------------+
///     | uint32  header_len      |
///     +-------------------------+
///     | header_len UTF-8 JSON   |
///     +-------------------------+
///     | payload_len bytes (raw) |
///     +-------------------------+
///
/// Mirrors `shout_daemon/protocol.py`.  Extracted from `DaemonClient`
/// so the encode/decode logic is isolated and unit-testable without
/// having to spin up a real Unix socket.
enum WireProtocol {
    /// Cap header at 1 MiB; cap payload at 1 GiB.  Same constants as the
    /// Python side.  See `shout_daemon/protocol.py`.
    static let maxHeaderBytes: Int = 1 << 20
    static let maxPayloadBytes: Int = 1 << 30

    /// Build a complete frame.  Overwrites `payload_len` from the actual
    /// payload size so callers don't have to keep them in sync.
    static func encodeFrame(header: [String: Any], payload: Data = Data()) throws -> Data {
        var h = header
        h["payload_len"] = payload.count
        let hData = try JSONSerialization.data(
            withJSONObject: h, options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard hData.count <= maxHeaderBytes else {
            throw SubShoutError.daemonProtocol("header too large: \(hData.count) bytes")
        }
        guard payload.count <= maxPayloadBytes else {
            throw SubShoutError.daemonProtocol("payload too large: \(payload.count) bytes")
        }
        var prefix = UInt32(hData.count).bigEndian
        var frame = Data(capacity: 4 + hData.count + payload.count)
        withUnsafeBytes(of: &prefix) { frame.append(contentsOf: $0) }
        frame.append(hData)
        if !payload.isEmpty { frame.append(payload) }
        return frame
    }

    /// Decode the 4-byte big-endian length prefix.
    static func headerLength(fromPrefix bytes: Data) -> UInt32 {
        precondition(bytes.count >= 4, "need 4 bytes for length prefix")
        return bytes.withUnsafeBytes { raw -> UInt32 in
            UInt32(bigEndian: raw.loadUnaligned(as: UInt32.self))
        }
    }

    /// Decode a complete frame from a single contiguous buffer.  Used by
    /// tests; the production receive path streams via `recvExactly`.
    static func decodeFrame(_ data: Data) throws -> (header: [String: Any], payload: Data) {
        guard data.count >= 4 else {
            throw SubShoutError.daemonProtocol("frame too short for length prefix")
        }
        let prefix = data.prefix(4)
        let hlen = Int(headerLength(fromPrefix: prefix))
        guard hlen > 0, hlen <= maxHeaderBytes else {
            throw SubShoutError.daemonProtocol("bad header_len: \(hlen)")
        }
        guard data.count >= 4 + hlen else {
            throw SubShoutError.daemonProtocol("frame truncated in header")
        }
        let hData = data.subdata(in: 4..<(4 + hlen))
        guard let header = try JSONSerialization.jsonObject(with: hData) as? [String: Any] else {
            throw SubShoutError.daemonProtocol("header is not a JSON object")
        }
        let payloadLen = (header["payload_len"] as? Int) ?? 0
        guard payloadLen >= 0, payloadLen <= maxPayloadBytes else {
            throw SubShoutError.daemonProtocol("bad payload_len: \(payloadLen)")
        }
        guard data.count >= 4 + hlen + payloadLen else {
            throw SubShoutError.daemonProtocol("frame truncated in payload")
        }
        let payload = payloadLen > 0
            ? data.subdata(in: (4 + hlen)..<(4 + hlen + payloadLen))
            : Data()
        return (header, payload)
    }
}
