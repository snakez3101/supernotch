import Foundation

// CONTRACT FILE (SPEC §D.7). Owner: claude-core.

/// Newline-delimited JSON framing used on the hook socket: one compact JSON object per line, `\n`-terminated.
public enum NDJSON {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }

    /// Encodes `value` as one line (including the trailing `\n`). Raw newlines inside strings are escaped, so
    /// the output never contains an embedded `\n`. Types with an `NDJSONOrderedRepresentable` form (e.g.
    /// `HookReply`) are written with our order-preserving writer, so `updatedPermissions` reach Claude Code
    /// exactly as they were suggested.
    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        var data: Data
        if let ordered = value as? any NDJSONOrderedRepresentable {
            data = Data(ordered.orderedJSON.serialized().utf8)
        } else {
            data = try makeEncoder().encode(value)
        }
        data.append(0x0A)
        return data
    }

    /// Decodes one line (with or without the trailing `\n`).
    public static func decodeLine<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        var trimmed = line
        while let last = trimmed.last, last == 0x0A || last == 0x0D { trimmed.removeLast() }
        return try JSONDecoder().decode(T.self, from: trimmed)
    }
}

/// A wire type that can render itself as an insertion-ordered `JSONValue` (JSONEncoder does not keep key order).
public protocol NDJSONOrderedRepresentable {
    var orderedJSON: JSONValue { get }
}

extension HookReply: NDJSONOrderedRepresentable {
    /// `{"v":1,"id":"…","decision":{"behavior":…}}` with `decision` in the documented field order.
    public var orderedJSON: JSONValue {
        var object = JSONObject()
        object["v"] = .number(Double(v))
        object["id"] = .string(id)
        object["decision"] = decision.flatMap { $0.hookOutput["hookSpecificOutput"]?["decision"] } ?? .null
        return .object(object)
    }
}

/// Accumulates bytes from a stream socket and yields complete lines.
public struct NDJSONLineBuffer: Sendable {
    public enum Failure: Error, Sendable, Equatable { case lineTooLong(limit: Int) }

    public let maxLineBytes: Int
    private var pending = Data()

    public init(maxLineBytes: Int = IPCConfig.maxMessageBytes) {
        self.maxLineBytes = maxLineBytes
    }

    /// Appends `chunk` and returns every complete, non-empty line (without the `\n`).
    /// Throws when a single line grows beyond `maxLineBytes` (the connection should then be dropped).
    public mutating func append(_ chunk: Data) throws -> [Data] {
        pending.append(chunk)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            pending = Data(pending[pending.index(after: newline)...])
            if !line.isEmpty { lines.append(Data(line)) }
        }
        if pending.count > maxLineBytes { throw Failure.lineTooLong(limit: maxLineBytes) }
        return lines
    }

    /// Bytes received after the last newline (a peer that closes without `\n` may leave a final message here).
    public var remainder: Data { pending }
}
