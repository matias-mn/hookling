import Foundation
import HooklingCore

enum EventServerError: Error, CustomStringConvertible {
    case pathTooLong(String)
    case cannotCreateDirectory(String)
    case socketFailed(Int32)
    case bindFailed(String, Int32)
    case listenFailed(Int32)
    case alreadyRunning(String)

    var description: String {
        switch self {
        case .pathTooLong(let path):
            return "socket path is too long for sockaddr_un: \(path)"
        case .cannotCreateDirectory(let path):
            return "could not create \(path)"
        case .socketFailed(let code):
            return "socket() failed: \(String(cString: strerror(code)))"
        case .bindFailed(let path, let code):
            return "bind(\(path)) failed: \(String(cString: strerror(code)))"
        case .listenFailed(let code):
            return "listen() failed: \(String(cString: strerror(code)))"
        case .alreadyRunning(let path):
            return "another Hookling is already listening on \(path)"
        }
    }
}

/// Listens on a Unix domain socket for pet events.
///
/// A filesystem socket rather than a loopback port, deliberately: it cannot be
/// reached from another machine even by mistake, it is protected by ordinary file
/// permissions, and its mere existence is the "is the pet running?" test the hook
/// needs in order to fail open.
///
/// Clients are expected to write one JSON line and close. The handler runs on the
/// main queue (where the pet lives) and may return a reply, which is written back
/// before the connection closes — that is how `hooklingctl status` gets an answer.
final class EventServer {
    /// One line per message; anything longer than this is refused without being
    /// parsed. Legitimate messages are around 60 bytes.
    private static let maximumRequestBytes = 8 * 1024

    private let path: String
    private let queue = DispatchQueue(label: "dev.hookling.socket")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    /// Returns optional reply text. Always invoked on the main queue.
    private let handler: (Result<PetMessage, any Error>) -> String?

    init(path: String, handler: @escaping (Result<PetMessage, any Error>) -> String?) {
        self.path = path
        self.handler = handler
    }

    var socketPath: String { path }

    // MARK: - Lifecycle

    func start() throws {
        guard HooklingSocket.isUsable(path: path) else {
            throw EventServerError.pathTooLong(path)
        }

        let directory = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw EventServerError.cannotCreateDirectory(directory)
        }

        try removeStaleSocket()

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw EventServerError.socketFailed(errno) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.utf8CString.withUnsafeBytes { source in
                buffer.copyMemory(from: source)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw EventServerError.bindFailed(path, code)
        }

        // Owner-only: nothing else on the machine can drive the pet.
        chmod(path, 0o600)

        guard listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw EventServerError.listenFailed(code)
        }

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
    }

    /// Remove a socket left behind by a crash, but never one a live pet is using.
    private func removeStaleSocket() throws {
        guard FileManager.default.fileExists(atPath: path) else { return }

        // If something answers, it is not stale.
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        if probe >= 0 {
            defer { close(probe) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                path.utf8CString.withUnsafeBytes { buffer.copyMemory(from: $0) }
            }
            let size = socklen_t(MemoryLayout<sockaddr_un>.size)
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(probe, $0, size)
                }
            }
            if connected == 0 { throw EventServerError.alreadyRunning(path) }
        }

        unlink(path)
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        listenFD = -1
        unlink(path)
    }

    // MARK: - Connections

    private func acceptOne() {
        let clientFD = accept(listenFD, nil, nil)
        guard clientFD >= 0 else { return }

        // Bound how long a misbehaving client can hold the queue. The hook gives
        // up after ~150ms anyway.
        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let request = readRequest(from: clientFD)
        let lines = request
            .split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            .map { Data($0) }

        guard !lines.isEmpty else {
            close(clientFD)
            return
        }

        // The pet lives on the main queue, so decisions are made there. Both
        // queues are serial, so ordering is preserved and there is no lock.
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                close(clientFD)
                return
            }
            var replies: [String] = []
            for line in lines {
                let result = Result { try EventCodec.decode(line: line) }
                if let reply = self.handler(result) { replies.append(reply) }
            }
            self.queue.async {
                if !replies.isEmpty {
                    var payload = Array((replies.joined(separator: "\n") + "\n").utf8)
                    _ = write(clientFD, &payload, payload.count)
                }
                close(clientFD)
            }
        }
    }

    private func readRequest(from fd: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while data.count < Self.maximumRequestBytes {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
            // A single line is the normal case; stop as soon as we have one so a
            // client that writes without closing is not waited on.
            if data.contains(UInt8(ascii: "\n")) { break }
        }
        return data
    }
}
