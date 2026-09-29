import Foundation

// CONTRACT FILE (SPEC §D). Owner: claude-core. Order-preserving JSON parser + writer.
// Why our own: JSONSerialization/JSONDecoder do not preserve object key order, and we must rewrite
// the user's ~/.claude/settings.json without shuffling it (SPEC §D.6).

public struct JSONParseError: Error, Sendable, Hashable, CustomStringConvertible {
    public let message: String
    public let offset: Int
    public var description: String { "JSON parse error at byte \(offset): \(message)" }
}

extension JSONValue {
    /// Strict RFC 8259 parse (no comments, no trailing commas). Leading UTF-8 BOM is tolerated.
    public static func parse(_ data: Data) throws -> JSONValue {
        var parser = Parser(bytes: Array(data))
        return try parser.parseDocument()
    }

    public static func parse(_ string: String) throws -> JSONValue {
        try parse(Data(string.utf8))
    }

    /// Serialise. `pretty` uses 2-space indentation and `"key": value`, matching
    /// `JSON.stringify(value, null, 2)` which is how Claude Code writes settings.json.
    public func serialized(pretty: Bool = false) -> String {
        var out = ""
        Writer.write(self, into: &out, pretty: pretty, indent: 0)
        return out
    }

    public func serializedData(pretty: Bool = false) -> Data {
        var text = serialized(pretty: pretty)
        if pretty { text.append("\n") }
        return Data(text.utf8)
    }
}

// MARK: - Parser

private struct Parser {
    let bytes: [UInt8]
    var index = 0
    var depth = 0
    static let maxDepth = 512

    init(bytes: [UInt8]) {
        self.bytes = bytes
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { index = 3 }
    }

    mutating func parseDocument() throws -> JSONValue {
        skipWhitespace()
        let value = try parseValue()
        skipWhitespace()
        guard index == bytes.count else { throw error("unexpected trailing characters") }
        return value
    }

    func error(_ message: String) -> JSONParseError { JSONParseError(message: message, offset: index) }

    mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    mutating func parseValue() throws -> JSONValue {
        guard index < bytes.count else { throw error("unexpected end of input") }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expectLiteral("true"); return .bool(true)
        case UInt8(ascii: "f"): try expectLiteral("false"); return .bool(false)
        case UInt8(ascii: "n"): try expectLiteral("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try parseNumber()
        default: throw error("unexpected character")
        }
    }

    mutating func expectLiteral(_ literal: String) throws {
        let utf8 = Array(literal.utf8)
        guard index + utf8.count <= bytes.count, Array(bytes[index..<index + utf8.count]) == utf8 else {
            throw error("invalid literal")
        }
        index += utf8.count
    }

    mutating func enter() throws {
        depth += 1
        if depth > Parser.maxDepth { throw error("nesting too deep") }
    }

    mutating func parseObject() throws -> JSONValue {
        try enter()
        defer { depth -= 1 }
        index += 1  // {
        var object = JSONObject()
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            index += 1
            return .object(object)
        }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw error("expected key") }
            let key = try parseString()
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw error("expected ':'") }
            index += 1
            skipWhitespace()
            object[key] = try parseValue()  // duplicate keys: last one wins, first position kept
            skipWhitespace()
            guard index < bytes.count else { throw error("unterminated object") }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
                continue
            }
            if bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(object)
            }
            throw error("expected ',' or '}'")
        }
    }

    mutating func parseArray() throws -> JSONValue {
        try enter()
        defer { depth -= 1 }
        index += 1  // [
        var array: [JSONValue] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
            index += 1
            return .array(array)
        }
        while true {
            skipWhitespace()
            array.append(try parseValue())
            skipWhitespace()
            guard index < bytes.count else { throw error("unterminated array") }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
                continue
            }
            if bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array(array)
            }
            throw error("expected ',' or ']'")
        }
    }

    mutating func parseNumber() throws -> JSONValue {
        let start = index
        if bytes[index] == UInt8(ascii: "-") { index += 1 }
        func isDigit(_ byte: UInt8) -> Bool { byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") }
        guard index < bytes.count, isDigit(bytes[index]) else { throw error("invalid number") }
        if bytes[index] == UInt8(ascii: "0") {
            index += 1
        } else {
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            guard index < bytes.count, isDigit(bytes[index]) else { throw error("invalid fraction") }
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
                index += 1
            }
            guard index < bytes.count, isDigit(bytes[index]) else { throw error("invalid exponent") }
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        guard let value = Double(text) else { throw error("invalid number") }
        return .number(value)
    }

    mutating func parseHex4() throws -> UInt32 {
        guard index + 4 <= bytes.count else { throw error("truncated \\u escape") }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            value <<= 4
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): value |= UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): value |= UInt32(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): value |= UInt32(byte - UInt8(ascii: "A") + 10)
            default: throw error("invalid hex digit")
            }
            index += 1
        }
        return value
    }

    mutating func parseString() throws -> String {
        index += 1  // opening quote
        var buffer: [UInt8] = []
        while true {
            guard index < bytes.count else { throw error("unterminated string") }
            let byte = bytes[index]
            index += 1
            switch byte {
            case UInt8(ascii: "\""):
                return String(decoding: buffer, as: UTF8.self)
            case UInt8(ascii: "\\"):
                guard index < bytes.count else { throw error("unterminated escape") }
                let escaped = bytes[index]
                index += 1
                switch escaped {
                case UInt8(ascii: "\""): buffer.append(UInt8(ascii: "\""))
                case UInt8(ascii: "\\"): buffer.append(UInt8(ascii: "\\"))
                case UInt8(ascii: "/"): buffer.append(UInt8(ascii: "/"))
                case UInt8(ascii: "b"): buffer.append(0x08)
                case UInt8(ascii: "f"): buffer.append(0x0C)
                case UInt8(ascii: "n"): buffer.append(0x0A)
                case UInt8(ascii: "r"): buffer.append(0x0D)
                case UInt8(ascii: "t"): buffer.append(0x09)
                case UInt8(ascii: "u"):
                    var scalarValue = try parseHex4()
                    if (0xD800...0xDBFF).contains(scalarValue) {
                        // Expect a low surrogate.
                        if index + 6 <= bytes.count, bytes[index] == UInt8(ascii: "\\"),
                            bytes[index + 1] == UInt8(ascii: "u")
                        {
                            index += 2
                            let low = try parseHex4()
                            guard (0xDC00...0xDFFF).contains(low) else { throw error("invalid low surrogate") }
                            scalarValue = 0x10000 + ((scalarValue - 0xD800) << 10) + (low - 0xDC00)
                        } else {
                            scalarValue = 0xFFFD
                        }
                    } else if (0xDC00...0xDFFF).contains(scalarValue) {
                        scalarValue = 0xFFFD
                    }
                    let scalar = Unicode.Scalar(scalarValue) ?? "\u{FFFD}"
                    buffer.append(contentsOf: Array(String(Character(scalar)).utf8))
                default:
                    throw error("invalid escape")
                }
            default:
                if byte < 0x20 { throw error("control character in string") }
                buffer.append(byte)
            }
        }
    }
}

// MARK: - Writer

private enum Writer {
    static func write(_ value: JSONValue, into out: inout String, pretty: Bool, indent: Int) {
        switch value {
        case .null: out += "null"
        case .bool(let flag): out += flag ? "true" : "false"
        case .number(let number): out += format(number)
        case .string(let string): writeString(string, into: &out)
        case .array(let array):
            if array.isEmpty {
                out += "[]"
                return
            }
            out += "["
            for (offset, element) in array.enumerated() {
                if offset > 0 { out += "," }
                if pretty { newline(&out, indent + 1) }
                write(element, into: &out, pretty: pretty, indent: indent + 1)
            }
            if pretty { newline(&out, indent) }
            out += "]"
        case .object(let object):
            if object.isEmpty {
                out += "{}"
                return
            }
            out += "{"
            for (offset, pair) in object.pairs.enumerated() {
                if offset > 0 { out += "," }
                if pretty { newline(&out, indent + 1) }
                writeString(pair.key, into: &out)
                out += pretty ? ": " : ":"
                write(pair.value, into: &out, pretty: pretty, indent: indent + 1)
            }
            if pretty { newline(&out, indent) }
            out += "}"
        }
    }

    static func newline(_ out: inout String, _ level: Int) {
        out += "\n"
        out += String(repeating: "  ", count: level)
    }

    static func format(_ number: Double) -> String {
        guard number.isFinite else { return "null" }
        if number.rounded() == number, abs(number) < 9.0e15 {
            return String(Int64(number))
        }
        return String(number)
    }

    static func writeString(_ string: String, into out: inout String) {
        out += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}
