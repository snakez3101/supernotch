// Owner: claude-core. Minimal blocking Unix-domain stream socket client (Darwin + Glibc).

import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

final class UnixSocketClient {
    private var fd: Int32

    /// Connects or returns nil (missing socket, refused, path too long).
    init?(path: String) {
        #if canImport(Darwin)
            let type = SOCK_STREAM
        #else
            let type = Int32(SOCK_STREAM.rawValue)
        #endif
        let descriptor = socket(AF_UNIX, type, 0)
        guard descriptor >= 0 else { return nil }
        fd = descriptor

        #if canImport(Darwin)
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else {
            Darwin_close(fd)
            return nil
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
            buffer[bytes.count] = 0
        }
        #if canImport(Darwin)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) }
        }
        guard result == 0 else {
            Darwin_close(fd)
            return nil
        }
    }

    func close() {
        if fd >= 0 {
            Darwin_close(fd)
            fd = -1
        }
    }

    deinit { close() }

    /// Writes all bytes; false on error or timeout.
    func writeAll(_ data: Data, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            guard wait(for: Int16(POLLOUT), until: deadline) else { return false }
            let written = bytes[offset...].withUnsafeBytes { buffer in
                write(fd, buffer.baseAddress, buffer.count)
            }
            if written < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return false
            }
            offset += written
        }
        return true
    }

    /// Reads until the first `\n` (returned without it). nil on EOF, error or timeout.
    func readLine(timeout: TimeInterval) -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        var collected = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if let newline = collected.firstIndex(of: 0x0A) {
                return collected[collected.startIndex..<newline]
            }
            guard collected.count <= IPCLimits.maxReplyBytes, wait(for: Int16(POLLIN), until: deadline) else {
                return nil
            }
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return nil }
            collected.append(contentsOf: chunk[0..<count])
        }
    }

    private func wait(for events: Int16, until deadline: Date) -> Bool {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return false }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let millis = Int32(min(remaining * 1000, Double(Int32.max)))
            let result = poll(&descriptor, 1, max(millis, 1))
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { return false }
            if descriptor.revents & Int16(POLLERR | POLLNVAL) != 0 { return false }
            // POLLHUP with pending data still allows a read that returns the data, then 0.
            return true
        }
    }
}

enum IPCLimits {
    static let maxReplyBytes = 1 * 1024 * 1024
}

/// `close` is shadowed by the method name inside the class.
@inline(__always) private func Darwin_close(_ fd: Int32) {
    #if canImport(Darwin)
        _ = Darwin.close(fd)
    #else
        _ = Glibc.close(fd)
    #endif
}
