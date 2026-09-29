// Owner: claude-app. Unix domain socket server for `supernotch-hook` (SPEC §D.7).
//
// * One connection per hook call, one NDJSON `HookEnvelope` line per connection (hook → app).
// * Non-blocking events: read the line, deliver it, close.
// * PermissionRequest (`expectsReply`): keep the connection open until the app answers (`reply`), the peer
//   closes (answered in the terminal / hook timed out → `.connectionClosed`), or our own safety timeout.
// * All socket IO runs on one private serial queue. Nothing here touches the main actor; the owner hops.

import Foundation
import SuperNotchCore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

nonisolated final class ClaudeHookSocketServer: @unchecked Sendable {
    nonisolated enum Event: Sendable {
        /// A decoded envelope. For `expectsReply` envelopes the connection stays open until `reply(...)`.
        case envelope(HookEnvelope)
        /// A held PermissionRequest connection closed before we answered it.
        case connectionClosed(requestID: String)
    }

    nonisolated struct StartError: Error, Sendable, CustomStringConvertible {
        let description: String
    }

    let path: String
    /// Connections that never send a complete line are dropped after this long.
    let idleTimeout: TimeInterval
    /// Safety net for held PermissionRequest connections (the hook itself gives up after 290 s).
    let pendingTimeout: TimeInterval

    private let queue = DispatchQueue(label: "io.github.snakez3101.supernotch.claude.socket", qos: .userInitiated)
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var handler: (@Sendable (Event) -> Void)?
    private var connections: [Int32: Connection] = [:]
    private var pendingByRequestID: [String: Int32] = [:]
    /// We bound `path` (so `stop()` may remove it; never another instance's socket).
    private var ownsSocketFile = false

    private nonisolated final class Connection {
        let fd: Int32
        var source: DispatchSourceRead?
        var buffer = NDJSONLineBuffer(maxLineBytes: IPCConfig.maxMessageBytes)
        /// Set once the envelope of a blocking request has been delivered.
        var requestID: String?
        /// Bumped whenever the timeout is re-armed so stale timers do nothing.
        var timeoutGeneration = 0
        var isClosing = false

        init(fd: Int32) { self.fd = fd }
    }

    init(
        path: String, idleTimeout: TimeInterval = 5,
        pendingTimeout: TimeInterval = IPCConfig.permissionReplyTimeout + 8
    ) {
        self.path = path
        self.idleTimeout = idleTimeout
        self.pendingTimeout = pendingTimeout
    }

    deinit {
        // `stop()` should have been called; make sure the descriptor does not leak regardless.
        if listenFD >= 0 && acceptSource == nil { Self.closeDescriptor(listenFD) }
    }

    // MARK: - Lifecycle

    /// Binds and starts listening. Synchronous so the caller learns about failures (another instance
    /// running, path problems). `handler` is called on the private queue, in arrival order.
    func start(handler: @escaping @Sendable (Event) -> Void) throws {
        var failure: StartError?
        queue.sync {
            guard listenFD < 0 else { return }
            self.handler = handler
            do {
                try openListeningSocket()
            } catch let error as StartError {
                failure = error
            } catch {
                failure = StartError(description: "\(error)")
            }
        }
        if let failure { throw failure }
    }

    /// Stops listening, closes every connection (held hooks then fail open) and removes the socket file.
    func stop() {
        queue.sync {
            acceptSource?.cancel()
            acceptSource = nil
            listenFD = -1
            for connection in Array(connections.values) {
                close(connection, notify: false)
            }
            connections.removeAll()
            pendingByRequestID.removeAll()
            handler = nil
            if ownsSocketFile {
                unlink(path)
                ownsSocketFile = false
            }
        }
    }

    var isRunning: Bool { queue.sync { listenFD >= 0 } }

    /// Number of held PermissionRequest connections (diagnostics).
    var pendingCount: Int { queue.sync { pendingByRequestID.count } }

    // MARK: - Replies

    /// Answers a held PermissionRequest connection and closes it. `decision == nil` is a passthrough
    /// (the hook prints nothing, Claude Code shows its own prompt). No `.connectionClosed` event follows.
    func reply(requestID: String, decision: PermissionDecision?) {
        queue.async { [self] in
            guard let fd = pendingByRequestID.removeValue(forKey: requestID), let connection = connections[fd] else {
                Log.ipc.debug("reply for unknown/closed request \(requestID, privacy: .public)")
                return
            }
            let reply = HookReply(id: requestID, decision: decision)
            if let line = try? NDJSON.encodeLine(reply) {
                if !Self.writeAll(fd: fd, data: line, timeout: 1.0) {
                    Log.ipc.error("failed to write reply for \(requestID, privacy: .public)")
                }
            }
            connection.requestID = nil
            close(connection, notify: false)
        }
    }

    // MARK: - Listening socket (queue)

    private func openListeningSocket() throws {
        let directory = (path as NSString).deletingLastPathComponent
        if !directory.isEmpty {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        guard path.utf8.count < Self.sunPathCapacity else {
            throw StartError(description: "Socket path is too long: \(path)")
        }
        // A socket file that accepts connections belongs to another running instance: do not steal it.
        if FileManager.default.fileExists(atPath: path) {
            if Self.canConnect(to: path) {
                throw StartError(description: "Another SuperNotch instance is already listening")
            }
            unlink(path)
        }

        let fd = socket(AF_UNIX, Self.streamType, 0)
        guard fd >= 0 else { throw StartError(description: "socket() failed: errno \(errno)") }
        Self.setNonBlocking(fd)
        Self.setCloseOnExec(fd)

        var address = Self.makeAddress(path)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                bind(fd, raw, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            Self.closeDescriptor(fd)
            throw StartError(description: "bind() failed: errno \(code)")
        }
        ownsSocketFile = true
        // Owner-only (SPEC §D.7). The folder is private too, and every peer's uid is checked on accept.
        chmod(path, 0o600)
        guard listen(fd, 64) == 0 else {
            let code = errno
            Self.closeDescriptor(fd)
            unlink(path)
            ownsSocketFile = false
            throw StartError(description: "listen() failed: errno \(code)")
        }

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { Self.closeDescriptor(fd) }
        acceptSource = source
        source.resume()
        Log.ipc.info("hook socket listening at \(self.path, privacy: .public)")
    }

    private func acceptPending() {
        guard listenFD >= 0 else { return }
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                return  // EAGAIN / EWOULDBLOCK: drained.
            }
            guard Self.peerIsSameUser(fd) else {
                Log.ipc.error("rejected hook connection from another user")
                Self.closeDescriptor(fd)
                continue
            }
            Self.setNonBlocking(fd)
            Self.setCloseOnExec(fd)
            Self.disableSigpipe(fd)
            let connection = Connection(fd: fd)
            connections[fd] = connection
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.readAvailable(fd: fd) }
            source.setCancelHandler { Self.closeDescriptor(fd) }
            connection.source = source
            armTimeout(connection, after: idleTimeout)
            source.resume()
        }
    }

    // MARK: - Connections (queue)

    private func readAvailable(fd: Int32) {
        guard let connection = connections[fd], !connection.isClosing else { return }
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = chunk.withUnsafeMutableBytes { buffer in read(fd, buffer.baseAddress, buffer.count) }
            if count > 0 {
                let lines: [Data]
                do {
                    lines = try connection.buffer.append(Data(chunk[0..<count]))
                } catch {
                    Log.ipc.error("hook message too large, dropping connection")
                    close(connection, notify: true)
                    return
                }
                for line in lines where connection.requestID == nil {
                    handleLine(line, on: connection)
                    if connection.isClosing { return }
                }
                continue
            }
            if count == 0 {
                peerClosed(connection)
                return
            }
            switch errno {
            case EINTR:
                continue
            case EAGAIN, EWOULDBLOCK:
                return
            default:
                peerClosed(connection)
                return
            }
        }
    }

    private func peerClosed(_ connection: Connection) {
        // A hook that closed without a trailing newline may still have left one complete message behind.
        if connection.requestID == nil, !connection.buffer.remainder.isEmpty {
            handleLine(connection.buffer.remainder, on: connection)
            if connection.isClosing { return }
        }
        close(connection, notify: true)
    }

    private func handleLine(_ line: Data, on connection: Connection) {
        let envelope: HookEnvelope
        do {
            envelope = try NDJSON.decodeLine(HookEnvelope.self, from: line)
        } catch {
            Log.ipc.error("undecodable hook envelope (\(line.count, privacy: .public) bytes)")
            close(connection, notify: false)
            return
        }
        if envelope.expectsReply {
            // Hold the connection; the model answers via `reply(requestID:decision:)`.
            if let previous = pendingByRequestID[envelope.id], previous != connection.fd,
                let stale = connections[previous]
            {
                stale.requestID = nil
                close(stale, notify: false)
            }
            connection.requestID = envelope.id
            pendingByRequestID[envelope.id] = connection.fd
            armTimeout(connection, after: pendingTimeout)
            handler?(.envelope(envelope))
        } else {
            handler?(.envelope(envelope))
            close(connection, notify: false)
        }
    }

    private func armTimeout(_ connection: Connection, after interval: TimeInterval) {
        connection.timeoutGeneration += 1
        let generation = connection.timeoutGeneration
        let fd = connection.fd
        queue.asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self, let current = self.connections[fd], current === connection,
                current.timeoutGeneration == generation, !current.isClosing
            else { return }
            if current.requestID != nil {
                Log.ipc.info("permission connection timed out")
            }
            self.close(current, notify: true)
        }
    }

    /// Closes a connection. With `notify`, a held PermissionRequest reports `.connectionClosed`.
    private func close(_ connection: Connection, notify: Bool) {
        guard !connection.isClosing else { return }
        connection.isClosing = true
        connections[connection.fd] = nil
        if let requestID = connection.requestID {
            if pendingByRequestID[requestID] == connection.fd { pendingByRequestID[requestID] = nil }
            connection.requestID = nil
            if notify { handler?(.connectionClosed(requestID: requestID)) }
        }
        if let source = connection.source {
            connection.source = nil
            source.cancel()  // The cancel handler closes the descriptor.
        } else {
            Self.closeDescriptor(connection.fd)
        }
    }

    // MARK: - POSIX helpers

    private static var streamType: Int32 {
        #if canImport(Darwin)
            return SOCK_STREAM
        #else
            return Int32(SOCK_STREAM.rawValue)
        #endif
    }

    private static var sunPathCapacity: Int {
        MemoryLayout.size(ofValue: sockaddr_un().sun_path)
    }

    private static func makeAddress(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            let count = min(bytes.count, buffer.count - 1)
            for index in 0..<count { buffer[index] = bytes[index] }
            buffer[count] = 0
        }
        #if canImport(Darwin)
            address.sun_len = UInt8(truncatingIfNeeded: MemoryLayout<sockaddr_un>.size)
        #endif
        return address
    }

    /// True when something accepts connections on `path` (another running instance).
    private static func canConnect(to path: String) -> Bool {
        let fd = socket(AF_UNIX, streamType, 0)
        guard fd >= 0 else { return false }
        defer { closeDescriptor(fd) }
        var address = makeAddress(path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                connect(fd, raw, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }

    private static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
    }

    private static func setCloseOnExec(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFD, 0)
        if flags >= 0 { _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC) }
    }

    private static func disableSigpipe(_ fd: Int32) {
        #if canImport(Darwin)
            var one: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    private static func peerIsSameUser(_ fd: Int32) -> Bool {
        #if canImport(Darwin)
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0 else { return false }
            return uid == getuid()
        #else
            return true  // The 0600 socket mode already restricts access.
        #endif
    }

    /// Writes all bytes to a non-blocking descriptor, polling for writability up to `timeout`.
    private static func writeAll(fd: Int32, data: Data, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { buffer -> Int in
                #if canImport(Darwin)
                    return write(fd, buffer.baseAddress, buffer.count)
                #else
                    return send(fd, buffer.baseAddress, buffer.count, Int32(MSG_NOSIGNAL))
                #endif
            }
            if written > 0 {
                offset += written
                continue
            }
            if written < 0 && (errno == EINTR) { continue }
            if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { return false }
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&descriptor, 1, Int32(max(1, min(remaining * 1000, 1000))))
                continue
            }
            return false
        }
        return true
    }

    private static func closeDescriptor(_ fd: Int32) {
        #if canImport(Darwin)
            _ = Darwin.close(fd)
        #else
            _ = Glibc.close(fd)
        #endif
    }
}
