import Darwin
import Foundation

/// Blocking Unix-domain-socket client. Single-connection, single-thread
/// (the caller — `DaemonClient` — funnels all use through one serial
/// `DispatchQueue`).  Tiny on purpose: we don't need an event-driven socket
/// abstraction for a single-client request/response protocol.
final class UnixSocketClient {
    private var fd: Int32 = -1

    var isConnected: Bool { fd >= 0 }

    func connect(to path: String) throws {
        precondition(fd < 0, "already connected")
        let s = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { throw posixError() }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        // Pack the path (with trailing NUL) into the fixed-size sun_path
        // tuple via a raw-bytes view of the field.  This avoids any
        // typed-pointer dance with the Swift-imported tuple type.
        let pathBytes = Array(path.utf8) + [0]
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= cap else {
            Darwin.close(s)
            throw SubShoutError.socketPathTooLong(path)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            pathBytes.withUnsafeBytes { src in
                _ = memcpy(dst.baseAddress!, src.baseAddress!, pathBytes.count)
            }
        }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { ap in
            ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(s, sa, len)
            }
        }
        guard rc == 0 else {
            let err = errno
            Darwin.close(s)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .ECONNREFUSED)
        }
        self.fd = s
    }

    func send(_ data: Data) throws {
        guard fd >= 0 else { throw POSIXError(.ENOTCONN) }
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let n = Darwin.send(fd, base.advanced(by: sent), data.count - sent, 0)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                sent += n
            }
        }
    }

    func recvExactly(_ n: Int) throws -> Data {
        guard fd >= 0 else { throw POSIXError(.ENOTCONN) }
        if n == 0 { return Data() }
        var buf = Data(count: n)
        try buf.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var got = 0
            while got < n {
                let r = Darwin.recv(fd, base.advanced(by: got), n - got, 0)
                if r < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                if r == 0 {
                    throw SubShoutError.daemonProtocol(
                        "connection closed with \(n - got) of \(n) bytes pending"
                    )
                }
                got += r
            }
        }
        return buf
    }

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    deinit { close() }

    private func posixError() -> Error {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
