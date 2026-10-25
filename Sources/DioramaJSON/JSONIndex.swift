/// A byte-offset index over a JSON document.
///
/// `JSONIndex` parses a UTF-8 JSON document once and records the byte range of every value
/// without decoding string contents (except object keys). This lets callers locate a value
/// precisely and replace exactly those bytes, leaving every other byte of the document
/// untouched — the basis of Diorama's "splice, never re-serialize" rule (decision D10).
public struct JSONNode: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case object, array, string, number, bool, null
    }

    public struct Member: Sendable, Equatable {
        public let key: String
        public let value: JSONNode
    }

    public let kind: Kind
    /// Byte range of the value in the source document, including quotes/brackets.
    public let range: Range<Int>
    public let members: [Member]
    public let elements: [JSONNode]

    init(kind: Kind, range: Range<Int>, members: [Member] = [], elements: [JSONNode] = []) {
        self.kind = kind
        self.range = range
        self.members = members
        self.elements = elements
    }

    /// First member with the given key (JSON permits duplicates; the first wins, matching
    /// what we read but the API may differ — callers that care should check `members`).
    public subscript(key: String) -> JSONNode? {
        guard kind == .object else { return nil }
        return members.first(where: { $0.key == key })?.value
    }

    public subscript(index: Int) -> JSONNode? {
        guard kind == .array, elements.indices.contains(index) else { return nil }
        return elements[index]
    }
}

public struct JSONParseError: Error, Sendable, Equatable, CustomStringConvertible {
    public let offset: Int
    public let message: String
    public var description: String { "JSON parse error at byte \(offset): \(message)" }

    public init(offset: Int, message: String) {
        self.offset = offset
        self.message = message
    }
}

public enum JSONIndex {
    public static let maxDepth = 512

    /// Parse a complete JSON document. Leading/trailing whitespace is allowed.
    public static func parse(_ bytes: [UInt8]) throws(JSONParseError) -> JSONNode {
        try bytes.withUnsafeBufferPointer { (buf) throws(JSONParseError) -> JSONNode in
            var parser = Parser(buf: buf)
            parser.skipWhitespace()
            let node = try parser.parseValue(depth: 0)
            parser.skipWhitespace()
            guard parser.pos == buf.count else {
                throw JSONParseError(offset: parser.pos, message: "trailing characters")
            }
            return node
        }
    }

    /// Decode the string value at `node` (which must be a `.string` node).
    public static func decodeString(_ bytes: [UInt8], _ node: JSONNode) throws(JSONParseError) -> String {
        guard node.kind == .string else {
            throw JSONParseError(offset: node.range.lowerBound, message: "not a string")
        }
        return try bytes.withUnsafeBufferPointer { (buf) throws(JSONParseError) -> String in
            try decodeStringContents(buf, from: node.range.lowerBound + 1, to: node.range.upperBound - 1)
        }
    }

    static func decodeStringContents(
        _ buf: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int
    ) throws(JSONParseError) -> String {
        // Fast path: no escapes.
        var hasEscape = false
        for i in start..<end where buf[i] == UInt8(ascii: "\\") {
            hasEscape = true
            break
        }
        if !hasEscape {
            return String(decoding: UnsafeBufferPointer(rebasing: buf[start..<end]), as: UTF8.self)
        }
        var out = [UInt8]()
        out.reserveCapacity(end - start)
        var i = start
        while i < end {
            let c = buf[i]
            if c != UInt8(ascii: "\\") {
                out.append(c)
                i += 1
                continue
            }
            guard i + 1 < end else { throw JSONParseError(offset: i, message: "dangling escape") }
            let e = buf[i + 1]
            i += 2
            switch e {
            case UInt8(ascii: "\""): out.append(0x22)
            case UInt8(ascii: "\\"): out.append(0x5C)
            case UInt8(ascii: "/"): out.append(0x2F)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "u"):
                var scalar = try hex4(buf, at: i, end: end)
                i += 4
                if (0xD800...0xDBFF).contains(scalar) {
                    // Expect a low surrogate.
                    if i + 6 <= end, buf[i] == UInt8(ascii: "\\"), buf[i + 1] == UInt8(ascii: "u") {
                        let low = try hex4(buf, at: i + 2, end: end)
                        if (0xDC00...0xDFFF).contains(low) {
                            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                            i += 6
                        } else {
                            scalar = 0xFFFD
                        }
                    } else {
                        scalar = 0xFFFD
                    }
                } else if (0xDC00...0xDFFF).contains(scalar) {
                    scalar = 0xFFFD
                }
                let us = Unicode.Scalar(scalar) ?? "\u{FFFD}"
                out.append(contentsOf: Array(String(Character(us)).utf8))
            default:
                throw JSONParseError(offset: i - 1, message: "invalid escape")
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func hex4(_ buf: UnsafeBufferPointer<UInt8>, at i: Int, end: Int) throws(JSONParseError) -> UInt32 {
        guard i + 4 <= end else { throw JSONParseError(offset: i, message: "short \\u escape") }
        var v: UInt32 = 0
        for k in 0..<4 {
            let c = buf[i + k]
            let d: UInt32
            switch c {
            case 0x30...0x39: d = UInt32(c - 0x30)
            case 0x41...0x46: d = UInt32(c - 0x41 + 10)
            case 0x61...0x66: d = UInt32(c - 0x61 + 10)
            default: throw JSONParseError(offset: i + k, message: "bad hex digit")
            }
            v = v << 4 | d
        }
        return v
    }

    struct Parser {
        let buf: UnsafeBufferPointer<UInt8>
        var pos = 0

        init(buf: UnsafeBufferPointer<UInt8>) { self.buf = buf }

        mutating func skipWhitespace() {
            while pos < buf.count {
                switch buf[pos] {
                case 0x20, 0x09, 0x0A, 0x0D: pos += 1
                default: return
                }
            }
        }

        func fail(_ message: String) -> JSONParseError { JSONParseError(offset: pos, message: message) }

        private struct Container {
            let isObject: Bool
            let start: Int
            var members: [JSONNode.Member] = []
            var elements: [JSONNode] = []
            var pendingKey: String = ""
        }

        /// Iterative (explicit-stack) parse so nesting depth can never overflow a thread stack.
        mutating func parseValue(depth: Int) throws(JSONParseError) -> JSONNode {
            var stack: [Container] = []
            outer: while true {
                skipWhitespace()
                guard pos < buf.count else { throw fail("unexpected end of input") }
                var value: JSONNode
                switch buf[pos] {
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    let isObject = buf[pos] == UInt8(ascii: "{")
                    let start = pos
                    pos += 1
                    skipWhitespace()
                    if pos < buf.count, buf[pos] == (isObject ? UInt8(ascii: "}") : UInt8(ascii: "]")) {
                        pos += 1
                        value = JSONNode(kind: isObject ? .object : .array, range: start..<pos)
                    } else {
                        guard stack.count + depth < JSONIndex.maxDepth else { throw fail("nesting too deep") }
                        stack.append(Container(isObject: isObject, start: start))
                        if isObject { stack[stack.count - 1].pendingKey = try readKey() }
                        continue outer
                    }
                case UInt8(ascii: "\""):
                    let start = pos
                    try scanString()
                    value = JSONNode(kind: .string, range: start..<pos)
                case UInt8(ascii: "t"): value = try literal("true", .bool)
                case UInt8(ascii: "f"): value = try literal("false", .bool)
                case UInt8(ascii: "n"): value = try literal("null", .null)
                case UInt8(ascii: "-"), 0x30...0x39: value = try parseNumber()
                default: throw fail("unexpected character")
                }
                // Attach the completed value to its parent, closing finished containers.
                while true {
                    guard !stack.isEmpty else { return value }
                    let top = stack.count - 1
                    if stack[top].isObject {
                        stack[top].members.append(.init(key: stack[top].pendingKey, value: value))
                    } else {
                        stack[top].elements.append(value)
                    }
                    skipWhitespace()
                    guard pos < buf.count else { throw fail(stack[top].isObject ? "unterminated object" : "unterminated array") }
                    if buf[pos] == UInt8(ascii: ",") {
                        pos += 1
                        if stack[top].isObject { stack[top].pendingKey = try readKey() }
                        continue outer
                    }
                    let close = stack[top].isObject ? UInt8(ascii: "}") : UInt8(ascii: "]")
                    guard buf[pos] == close else {
                        throw fail(stack[top].isObject ? "expected ',' or '}'" : "expected ',' or ']'")
                    }
                    pos += 1
                    let c = stack.removeLast()
                    value = c.isObject
                        ? JSONNode(kind: .object, range: c.start..<pos, members: c.members)
                        : JSONNode(kind: .array, range: c.start..<pos, elements: c.elements)
                }
            }
        }

        /// Reads `"key"` followed by `:` and returns the decoded key.
        private mutating func readKey() throws(JSONParseError) -> String {
            skipWhitespace()
            guard pos < buf.count, buf[pos] == UInt8(ascii: "\"") else { throw fail("expected key") }
            let keyStart = pos
            try scanString()
            let key = try JSONIndex.decodeStringContents(buf, from: keyStart + 1, to: pos - 1)
            skipWhitespace()
            guard pos < buf.count, buf[pos] == UInt8(ascii: ":") else { throw fail("expected ':'") }
            pos += 1
            return key
        }

        mutating func literal(_ word: StaticString, _ kind: JSONNode.Kind) throws(JSONParseError) -> JSONNode {
            let start = pos
            let n = word.utf8CodeUnitCount
            guard pos + n <= buf.count else { throw fail("unexpected end of input") }
            let p = word.utf8Start
            for k in 0..<n where buf[pos + k] != p[k] {
                throw fail("invalid literal")
            }
            pos += n
            return JSONNode(kind: kind, range: start..<pos)
        }

        mutating func parseNumber() throws(JSONParseError) -> JSONNode {
            let start = pos
            if buf[pos] == UInt8(ascii: "-") { pos += 1 }
            guard pos < buf.count else { throw fail("bad number") }
            if buf[pos] == UInt8(ascii: "0") {
                pos += 1
            } else if (0x31...0x39).contains(buf[pos]) {
                while pos < buf.count, (0x30...0x39).contains(buf[pos]) { pos += 1 }
            } else {
                throw fail("bad number")
            }
            if pos < buf.count, buf[pos] == UInt8(ascii: ".") {
                pos += 1
                let fracStart = pos
                while pos < buf.count, (0x30...0x39).contains(buf[pos]) { pos += 1 }
                guard pos > fracStart else { throw fail("bad fraction") }
            }
            if pos < buf.count, buf[pos] == UInt8(ascii: "e") || buf[pos] == UInt8(ascii: "E") {
                pos += 1
                if pos < buf.count, buf[pos] == UInt8(ascii: "+") || buf[pos] == UInt8(ascii: "-") { pos += 1 }
                let expStart = pos
                while pos < buf.count, (0x30...0x39).contains(buf[pos]) { pos += 1 }
                guard pos > expStart else { throw fail("bad exponent") }
            }
            return JSONNode(kind: .number, range: start..<pos)
        }

        /// Advances past a string starting at `pos` (which must be a quote).
        mutating func scanString() throws(JSONParseError) {
            pos += 1
            while pos < buf.count {
                let c = buf[pos]
                if c == UInt8(ascii: "\"") {
                    pos += 1
                    return
                } else if c == UInt8(ascii: "\\") {
                    pos += 2
                } else if c < 0x20 {
                    throw fail("control character in string")
                } else {
                    pos += 1
                }
            }
            throw fail("unterminated string")
        }

    }
}
