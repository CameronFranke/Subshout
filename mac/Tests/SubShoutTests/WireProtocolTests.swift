import XCTest
@testable import SubShout

/// Mirrors `tests/test_protocol.py` on the Python side.  These tests pin
/// down the Swift encoder so a daemon-side change can't silently break
/// the wire protocol — and vice versa.
final class WireProtocolTests: XCTestCase {

    // MARK: - encode

    func testEncodeOverridesPayloadLenInHeader() throws {
        // Even if the caller supplies a wrong payload_len, the encoder
        // overwrites it with the actual payload size.  This contract is
        // shared with the Python encoder.
        let payload = Data([0x61, 0x62, 0x63, 0x64])
        let frame = try WireProtocol.encodeFrame(
            header: ["type": "transcribe", "payload_len": 999],
            payload: payload
        )
        let prefix = frame.prefix(4)
        let hlen = Int(WireProtocol.headerLength(fromPrefix: prefix))
        let headerData = frame.subdata(in: 4..<(4 + hlen))
        let header = try JSONSerialization.jsonObject(with: headerData) as! [String: Any]
        XCTAssertEqual(header["payload_len"] as? Int, 4)
        XCTAssertEqual(frame.suffix(4), payload)
    }

    func testEncodeZeroPayloadOmitsPayloadBytes() throws {
        let frame = try WireProtocol.encodeFrame(header: ["type": "status"])
        let hlen = Int(WireProtocol.headerLength(fromPrefix: frame.prefix(4)))
        // 4 (length prefix) + hlen (header JSON) — nothing else.
        XCTAssertEqual(frame.count, 4 + hlen)
    }

    // MARK: - round-trip

    func testRoundTripWithPayload() throws {
        // Four little-endian float32 1.0s, used as opaque bytes.
        let payload = Data([0x00, 0x00, 0x80, 0x3F]) + Data([0x00, 0x00, 0x80, 0x3F])
            + Data([0x00, 0x00, 0x80, 0x3F]) + Data([0x00, 0x00, 0x80, 0x3F])
        let frame = try WireProtocol.encodeFrame(
            header: ["type": "transcribe", "sample_rate": 16000],
            payload: payload
        )
        let (h, p) = try WireProtocol.decodeFrame(frame)
        XCTAssertEqual(h["type"] as? String, "transcribe")
        XCTAssertEqual(h["sample_rate"] as? Int, 16000)
        XCTAssertEqual(h["payload_len"] as? Int, payload.count)
        XCTAssertEqual(p, payload)
    }

    func testRoundTripNoPayload() throws {
        let frame = try WireProtocol.encodeFrame(header: ["type": "status"])
        let (h, p) = try WireProtocol.decodeFrame(frame)
        XCTAssertEqual(h["type"] as? String, "status")
        XCTAssertEqual(p.count, 0)
    }

    // MARK: - decode error paths

    func testDecodeRejectsTruncatedHeader() {
        // Length prefix says 100 bytes of header but we only supply 10.
        var frame = Data(count: 4)
        frame.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: UInt32(100).bigEndian, as: UInt32.self)
        }
        frame.append(Data(count: 10))
        XCTAssertThrowsError(try WireProtocol.decodeFrame(frame)) { error in
            guard case SubShoutError.daemonProtocol(let msg) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertTrue(msg.contains("truncated"), "message: \(msg)")
        }
    }

    func testDecodeRejectsZeroHeaderLen() {
        var frame = Data(count: 4)
        frame.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: UInt32(0).bigEndian, as: UInt32.self)
        }
        XCTAssertThrowsError(try WireProtocol.decodeFrame(frame)) { error in
            guard case SubShoutError.daemonProtocol = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testDecodeRejectsNonObjectHeader() throws {
        // Header that's a JSON array, not an object.
        let arrayJSON = "[1,2,3]".data(using: .utf8)!
        var frame = Data(count: 4)
        frame.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: UInt32(arrayJSON.count).bigEndian, as: UInt32.self)
        }
        frame.append(arrayJSON)
        XCTAssertThrowsError(try WireProtocol.decodeFrame(frame))
    }

    func testDecodeRejectsTruncatedPayload() throws {
        let payload = Data([1, 2, 3, 4, 5])
        let full = try WireProtocol.encodeFrame(header: ["type": "x"], payload: payload)
        // Drop the last 2 payload bytes.
        let truncated = full.dropLast(2)
        XCTAssertThrowsError(try WireProtocol.decodeFrame(Data(truncated)))
    }

    // MARK: - byte-order pinning

    func testHeaderLengthIsBigEndian() {
        // Construct a known prefix: 0x00 0x00 0x00 0x05 → 5.  If the
        // accidental endian-swap regression sneaks in, this test fails.
        let prefix = Data([0x00, 0x00, 0x00, 0x05])
        XCTAssertEqual(WireProtocol.headerLength(fromPrefix: prefix), 5)
    }
}
