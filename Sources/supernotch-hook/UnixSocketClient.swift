// Owner: claude-core. Minimal Unix-domain stream socket client for the hook (Darwin + Glibc).
// Every operation has a deadline; every failure returns nil/false so the caller can fail open.

import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

final class UnixSocketClient {
    private var fd: Int32

    private init(fd: Int32) { self.fd = fd }

    deinit { close() }

    /// Connects within `timeout` or returns nil (missing socket, socket owned by another user, refused,
    /// backlog full, path too long).
    static func connect(path: String, timeout: TimeInterval) -> UnixSocketClient? {
        // Only talk to a socket file owned by us: in a shared directory another user could pre-create it and
        // answer our permission requests.
        var info = stat()
        guard stat(path, &info) == 0, info.st_uid == getuid() else { return nil }

        #if canImport(Darwin)
            let type = SOCK_STREAM
        #else
            let type = Int32(SOCK_STREAM.rawValue)
        #endif
        let descriptor = socket(AF_UNIX, type, 0)
        guard descriptor >= 0 else { return nil }
        let client = UnixSocketClient(fd: descriptor)

        #if canImport(Darwin)
            var one: Int32 = 1
            _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { return nil }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard !bytes.isEmpty, bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
            buffer[bytes.count] = 0
        }
        #if canImport(Darwin)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)

        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Glue.connect(descriptor, $0, length) }
            }
            if result == 0 { break }
            let error = errno
            if error == EINTR { continue }
            if error == EINPROGRESS {
                guard client.wait(for: Int16(POLLOUT), until: deadline) else { return nil }
                var socketError: Int32 = 0
                var size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &size) == 0, socketError == 0 else {
                    return nil
                }
                break
            }
            // EAGAIN: the listener's backlog is full (app busy). Retry briefly within the budget.
            guard error == EAGAIN, deadline.timeIntervalSinceNow > 0.01 else { return nil }
            usleep(5_000)
        }

        #if canImport(Darwin)
            var peerUID: uid_t = 0
            var peerGID: gid_t = 0
            guard getpeereid(descriptor, &peerUID, &peerGID) == 0, peerUID == getuid() else { return nil }
        #endif
        return client
    }

    func close() {
        if fd >= 0 {
            _ = Glue.close(fd)
            fd = -1
        }
    }

    /// Writes all bytes; false on error or timeout.
    func writeAll(_ data: Data, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { buffer in Glue.send(fd, buffer.baseAddress, buffer.count) }
            if written > 0 {
                offset += written
                continue
            }
            let error = errno
            if written < 0 && error == EINTR { continue }
            guard written < 0, error == EAGAIN, wait(for: Int16(POLLOUT), until: deadline) else { return false }
        }
        return true
    }

    /// Reads until the first `\n` (returned without it). nil on EOF, error, timeout or an oversized line.
    func readLine(timeout: TimeInterval, maxBytes: Int) -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        var collected = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if let newline = collected.firstIndex(of: 0x0A) {
                return Data(collected[collected.startIndex..<newline])
            }
            guard collected.count <= maxBytes else { return nil }
            let count = chunk.withUnsafeMutableBytes { Glue.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                collected.append(contentsOf: chunk[0..<count])
                continue
            }
            if count == 0 { return nil }  // EOF: the app closed without answering ⇒ passthrough
            let error = errno
            if error == EINTR { continue }
            guard error == EAGAIN, wait(for: Int16(POLLIN), until: deadline) else { return nil }
        }
    }

    private func wait(for events: Int16, until deadline: Date) -> Bool {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return false }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let millis = Int32(min(remaining * 1000, 60_000))
            let result = poll(&descriptor, 1, max(millis, 1))
            if result < 0 && errno == EINTR { continue }
            if result < 0 { return false }
            if result == 0 { continue }  // re-check the deadline (long waits are split into 60 s slices)
            if descriptor.revents & Int16(POLLNVAL) != 0 { return false }
            // POLLERR / POLLHUP: let the next read/send report it (a reply may still be buffered).
            return true
        }
    }
}

/// libc calls whose names are shadowed inside `UnixSocketClient` (its `close()` method) or need per-platform
/// flags.
enum Glue {
    static func close(_ fd: Int32) -> Int32 {
        #if canImport(Darwin)
            return Darwin.close(fd)
        #else
            return Glibc.close(fd)
        #endif
    }

    static func read(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
        #if canImport(Darwin)
            return Darwin.read(fd, buffer, count)
        #else
            return Glibc.read(fd, buffer, count)
        #endif
    }

    static func send(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
        #if canImport(Darwin)
            return Darwin.send(fd, buffer, count, 0)  // SO_NOSIGPIPE is set on the socket
        #else
            return Glibc.send(fd, buffer, count, Int32(MSG_NOSIGNAL))
        #endif
    }

    static func connect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
        #if canImport(Darwin)
            return Darwin.connect(fd, address, length)
        #else
            return Glibc.connect(fd, address, length)
        #endif
    }

    static func write(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
        #if canImport(Darwin)
            return Darwin.write(fd, buffer, count)
        #else
            return Glibc.write(fd, buffer, count)
        #endif
    }
}
