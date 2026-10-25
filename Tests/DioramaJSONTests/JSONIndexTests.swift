import Foundation
import Testing
@testable import DioramaJSON

@Suite struct JSONIndexTests {
    @Test func parsesNestedDocumentWithRanges() throws {
        let src = #"  {"a": [1, -2.5e3, true, null], "b": {"c": "x\"y"}, "d": ""}  "#
        let bytes = Array(src.utf8)
        let root = try JSONIndex.parse(bytes)
        #expect(root.kind == .object)
        let a = try #require(root["a"])
        #expect(a.elements.count == 4)
        #expect(String(decoding: bytes[a.elements[1].range], as: UTF8.self) == "-2.5e3")
        let c = try #require(root["b"]?["c"])
        #expect(try JSONIndex.decodeString(bytes, c) == "x\"y")
        #expect(String(decoding: bytes[c.range], as: UTF8.self) == #""x\"y""#)
        #expect(try JSONIndex.decodeString(bytes, try #require(root["d"])) == "")
    }

    @Test func decodesEscapesAndSurrogates() throws {
        let src = #""a\n\té😀\/\\""#
        let bytes = Array(src.utf8)
        let node = try JSONIndex.parse(bytes)
        #expect(try JSONIndex.decodeString(bytes, node) == "a\n\té😀/\\")
    }

    @Test(arguments: [
        "", "{", "[1,]", "{\"a\" 1}", "tru", "01", "1.", "\"abc", "{\"a\":1}x", "[\"\u{01}\"]", "-",
    ])
    func rejectsMalformed(_ src: String) {
        #expect(throws: JSONParseError.self) { try JSONIndex.parse(Array(src.utf8)) }
    }

    @Test func rejectsExcessiveDepth() {
        let src = String(repeating: "[", count: 600) + String(repeating: "]", count: 600)
        #expect(throws: JSONParseError.self) { try JSONIndex.parse(Array(src.utf8)) }
    }

    @Test func encodingRoundTripsThroughFoundation() throws {
        let samples = ["plain", "quote\"back\\slash", "ctrl\u{01}\u{1f}", "uni é 😀 \u{2028}", "nl\n\r\t", ""]
        for s in samples {
            let enc = JSONEncoding.string(s)
            let decoded = try JSONSerialization.jsonObject(with: Data(enc), options: [.fragmentsAllowed]) as? String
            #expect(decoded == s)
            #expect(try JSONIndex.decodeString(enc, try JSONIndex.parse(enc)) == s)
        }
    }

    @Test func spliceChangesOnlyTargetRanges() throws {
        let src = Array(#"{"keep":  "same",  "target": "old", "tail" :[1, 2]}"#.utf8)
        let root = try JSONIndex.parse(src)
        let target = try #require(root["target"])
        let out = try JSONSplice.apply(src, [(target.range, JSONEncoding.string("new \"value\""))])
        let expected = #"{"keep":  "same",  "target": "new \"value\"", "tail" :[1, 2]}"#
        #expect(String(decoding: out, as: UTF8.self) == expected)
        #expect(throws: SpliceError.self) {
            try JSONSplice.apply(src, [(0..<5, []), (3..<8, [])])
        }
    }

    @Test func canonicalBytesAreSortedAndStable() throws {
        let v = try JSONValue.parse(#"{"b": [1, {"z": null, "a": true}], "a": "x"}"#)
        #expect(v.canonicalString == #"{"a":"x","b":[1,{"a":true,"z":null}]}"#)
    }

    /// Property test: random documents serialized by Foundation (with random whitespace)
    /// parse to the same values, and every recorded range re-parses to the same value.
    @Test func randomDocumentsMatchFoundation() throws {
        var rng = SeededRNG(seed: 42)
        for _ in 0..<300 {
            let value = randomValue(&rng, depth: 0)
            let text = render(value, &rng)
            let bytes = Array(text.utf8)
            let root = try JSONIndex.parse(bytes)
            let ours = try JSONValue.from(bytes, root)
            let theirs = try JSONSerialization.jsonObject(with: Data(bytes), options: [.fragmentsAllowed])
            #expect(equivalent(ours, theirs), "mismatch for \(text)")
            try checkRanges(bytes, root)
        }
    }

    private func checkRanges(_ bytes: [UInt8], _ node: JSONNode) throws {
        let slice = Array(bytes[node.range])
        let reparsed = try JSONValue.parse(slice)
        #expect(reparsed == (try JSONValue.from(bytes, node)))
        for m in node.members { try checkRanges(bytes, m.value) }
        for e in node.elements { try checkRanges(bytes, e) }
    }
}

// MARK: - Helpers

struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func randomString(_ rng: inout SeededRNG) -> String {
    let alphabet: [Character] = ["a", "Z", "0", " ", "\"", "\\", "/", "\n", "\t", "\u{01}", "é", "😀", "{", "}", "[", ":", ","]
    let n = Int.random(in: 0...12, using: &rng)
    return String((0..<n).map { _ in alphabet.randomElement(using: &rng)! })
}

func randomValue(_ rng: inout SeededRNG, depth: Int) -> JSONValue {
    let choice = depth > 4 ? Int.random(in: 0...3, using: &rng) : Int.random(in: 0...5, using: &rng)
    switch choice {
    case 0: return .null
    case 1: return .bool(Bool.random(using: &rng))
    case 2: return .number(String(Int.random(in: -100_000...100_000, using: &rng)))
    case 3: return .string(randomString(&rng))
    case 4: return .array((0..<Int.random(in: 0...4, using: &rng)).map { _ in randomValue(&rng, depth: depth + 1) })
    default:
        var o: [String: JSONValue] = [:]
        for _ in 0..<Int.random(in: 0...4, using: &rng) { o[randomString(&rng)] = randomValue(&rng, depth: depth + 1) }
        return .object(o)
    }
}

func render(_ v: JSONValue, _ rng: inout SeededRNG) -> String {
    let ws = [" ", "", "\n", "\t", "  "]
    func w(_ rng: inout SeededRNG) -> String { ws.randomElement(using: &rng)! }
    switch v {
    case .null: return "null"
    case .bool(let b): return b ? "true" : "false"
    case .number(let n): return n
    case .string(let s): return String(decoding: JSONEncoding.string(s), as: UTF8.self)
    case .array(let a): return "[" + w(&rng) + a.map { render($0, &rng) }.joined(separator: "," + w(&rng)) + w(&rng) + "]"
    case .object(let o):
        let parts = o.map { k, val in String(decoding: JSONEncoding.string(k), as: UTF8.self) + w(&rng) + ":" + w(&rng) + render(val, &rng) }
        return "{" + w(&rng) + parts.joined(separator: ",") + w(&rng) + "}"
    }
}

func equivalent(_ a: JSONValue, _ b: Any) -> Bool {
    switch a {
    case .null: return b is NSNull
    case .bool(let x):
        guard let n = b as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return false }
        return n.boolValue == x
    case .number(let s): return (b as? NSNumber)?.int64Value == Int64(s)
    case .string(let s): return (b as? String) == s
    case .array(let arr):
        guard let o = b as? [Any], o.count == arr.count else { return false }
        return zip(arr, o).allSatisfy { equivalent($0, $1) }
    case .object(let obj):
        guard let o = b as? [String: Any], o.count == obj.count else { return false }
        return obj.allSatisfy { k, v in o[k].map { equivalent(v, $0) } ?? false }
    }
}

@Suite struct JSONDepthTests {
    @Test func acceptsDeepButAllowedNestingOnSecondaryThread() throws {
        let src = String(repeating: "[", count: 500) + "1" + String(repeating: "]", count: 500)
        let root = try JSONIndex.parse(Array(src.utf8))
        #expect(root.kind == .array)
    }
}
