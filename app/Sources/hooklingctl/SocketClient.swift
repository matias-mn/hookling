import Foundation
import HooklingCore

/// A one-shot client for the pet's Unix socket.
///
/// Fails open by design: if the pet is not running there is no socket, and every
/// call simply reports "not delivered" without erroring. That is what lets the
/// same code path be used from a Claude Code hook without ever getting in
/// Claude's way.
enum SocketClient {
    /// Total budget for connecting, writing and reading a reply. Short enough to
    /// be invisible in a hook, long enough for a busy pet to answer.
    static let timeout: TimeInterval = 0.5

    enum Outcome {
        case delivered(reply: String?)
        case notRunning
        case failed(String)
    }

    static func send(_ payload: Data, path: String, awaitReply: Bool) -> Outcome {
        guard HooklingSocket.isUsable(path: path) else {
            return .failed("socket path is too long: \(path)")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            return .notRunning
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failed("socket(): \(errnoText())") }
        defer { close(fd) }

        var send = timeval(tv_sec: 0, tv_usec: Int32(timeout * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &send, socklen_t(MemoryLayout<timeval>.size))
        var receive = send
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &receive, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.utf8CString.withUnsafeBytes { buffer.copyMemory(from: $0) }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        guard connected == 0 else {
            // A socket file with nobody behind it: a crashed pet, not an error.
            if errno == ECONNREFUSED || errno == ENOENT { return .notRunning }
            return .failed("connect(): \(errnoText())")
        }

        let bytes = Array(payload)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBufferPointer { buffer in
                write(fd, buffer.baseAddress, buffer.count)
            }
            if written <= 0 { return .failed("write(): \(errnoText())") }
            offset += written
        }

        guard awaitReply else { return .delivered(reply: nil) }

        // Tell the pet we are done writing, so it knows the request is complete.
        shutdown(fd, SHUT_WR)

        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while reply.count < 64 * 1024 {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            reply.append(contentsOf: buffer[0..<count])
        }
        return .delivered(reply: reply.isEmpty ? nil : String(decoding: reply))
    }

    private static func errnoText() -> String {
        String(cString: strerror(errno))
    }
}

private extension String {
    init(decoding data: Data) {
        self = String(data: data, encoding: .utf8) ?? ""
    }
}
