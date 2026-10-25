import Foundation

/// A fully decoded JSON value. Used for small documents (tool inputs, configuration),
/// never for re-serializing proxied request bodies.
public enum JSONValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    /// Numbers keep their source text so values round-trip exactly.
    case number(String)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int64.self) { self = .number(String(i)); return }
        if let d = try? c.decode(Double.self) { self = .number(JSONValue.format(d)); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        self = .object(try c.decode([String: JSONValue].self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if let i = Int64(n) { try c.encode(i) } else { try c.encode(Double(n) ?? 0) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    static func format(_ d: Double) -> String {
        if d.rounded() == d, abs(d) < 1e15 { return String(Int64(d)) }
        return String(d)
    }

    /// Decode the value at `node` from the source `bytes`.
    public static func from(_ bytes: [UInt8], _ node: JSONNode) throws(JSONParseError) -> JSONValue {
        switch node.kind {
        case .null: return .null
        case .bool: return .bool(bytes[node.range.lowerBound] == UInt8(ascii: "t"))
        case .number: return .number(String(decoding: bytes[node.range], as: UTF8.self))
        case .string: return .string(try JSONIndex.decodeString(bytes, node))
        case .array:
            var out: [JSONValue] = []
            out.reserveCapacity(node.elements.count)
            for e in node.elements { out.append(try from(bytes, e)) }
            return .array(out)
        case .object:
            var out: [String: JSONValue] = [:]
            for m in node.members where out[m.key] == nil { out[m.key] = try from(bytes, m.value) }
            return .object(out)
        }
    }

    public static func parse(_ bytes: [UInt8]) throws(JSONParseError) -> JSONValue {
        try from(bytes, try JSONIndex.parse(bytes))
    }

    public static func parse(_ string: String) throws(JSONParseError) -> JSONValue {
        try parse(Array(string.utf8))
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// Deterministic serialization (sorted keys) — suitable for hashing and storage.
    public var canonicalBytes: [UInt8] {
        var out: [UInt8] = []
        appendCanonical(to: &out)
        return out
    }

    public var canonicalString: String { String(decoding: canonicalBytes, as: UTF8.self) }

    private func appendCanonical(to out: inout [UInt8]) {
        switch self {
        case .null: out.append(contentsOf: Array("null".utf8))
        case .bool(let b): out.append(contentsOf: Array((b ? "true" : "false").utf8))
        case .number(let n): out.append(contentsOf: Array(n.utf8))
        case .string(let s): out.append(contentsOf: JSONEncoding.string(s))
        case .array(let a):
            out.append(UInt8(ascii: "["))
            for (i, v) in a.enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                v.appendCanonical(to: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .object(let o):
            out.append(UInt8(ascii: "{"))
            for (i, k) in o.keys.sorted().enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                out.append(contentsOf: JSONEncoding.string(k))
                out.append(UInt8(ascii: ":"))
                o[k]!.appendCanonical(to: &out)
            }
            out.append(UInt8(ascii: "}"))
        }
    }
}

public enum JSONEncoding {
    /// Encode `s` as a JSON string literal (with quotes). Non-ASCII characters are written as
    /// raw UTF-8; only `"`, `\` and control characters are escaped.
    public static func string(_ s: String) -> [UInt8] {
        var out: [UInt8] = [0x22]
        out.reserveCapacity(s.utf8.count + 2)
        for b in s.utf8 {
            switch b {
            case 0x22: out.append(contentsOf: [0x5C, 0x22])
            case 0x5C: out.append(contentsOf: [0x5C, 0x5C])
            case 0x0A: out.append(contentsOf: [0x5C, UInt8(ascii: "n")])
            case 0x0D: out.append(contentsOf: [0x5C, UInt8(ascii: "r")])
            case 0x09: out.append(contentsOf: [0x5C, UInt8(ascii: "t")])
            case 0x08: out.append(contentsOf: [0x5C, UInt8(ascii: "b")])
            case 0x0C: out.append(contentsOf: [0x5C, UInt8(ascii: "f")])
            case 0..<0x20:
                let hex = Array("0123456789abcdef".utf8)
                out.append(contentsOf: [0x5C, UInt8(ascii: "u"), 0x30, 0x30, hex[Int(b >> 4)], hex[Int(b & 0xF)]])
            default: out.append(b)
            }
        }
        out.append(0x22)
        return out
    }
}

public struct SpliceError: Error, Sendable, CustomStringConvertible {
    public let description: String
}

public enum JSONSplice {
    /// Replace the given byte ranges of `source` with new bytes. Ranges must not overlap.
    /// Bytes outside the ranges are copied verbatim.
    public static func apply(_ source: [UInt8], _ replacements: [(range: Range<Int>, bytes: [UInt8])]) throws -> [UInt8] {
        let sorted = replacements.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var out: [UInt8] = []
        out.reserveCapacity(source.count + sorted.reduce(0) { $0 + $1.bytes.count - $1.range.count })
        var cursor = 0
        for r in sorted {
            guard r.range.lowerBound >= cursor, r.range.upperBound <= source.count else {
                throw SpliceError(description: "overlapping or out-of-bounds splice range \(r.range)")
            }
            out.append(contentsOf: source[cursor..<r.range.lowerBound])
            out.append(contentsOf: r.bytes)
            cursor = r.range.upperBound
        }
        out.append(contentsOf: source[cursor...])
        return out
    }
}
