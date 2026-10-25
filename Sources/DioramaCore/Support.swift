import CryptoKit
import Foundation

// MARK: - Paths

/// Locations of Diorama's local state. Everything lives under one directory so tests and
/// alternative installs can point `DIORAMA_HOME` elsewhere.
public struct DioramaPaths: Sendable {
    public let home: URL

    public init(home: URL) { self.home = home }

    public static func `default`(environment: [String: String] = ProcessInfo.processInfo.environment) -> DioramaPaths {
        if let custom = environment["DIORAMA_HOME"], !custom.isEmpty {
            return DioramaPaths(home: URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true))
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return DioramaPaths(home: base.appendingPathComponent("Diorama", isDirectory: true))
    }

    public var database: URL { home.appendingPathComponent("diorama.sqlite") }
    public var blobs: URL { home.appendingPathComponent("blobs", isDirectory: true) }
    public var runs: URL { home.appendingPathComponent("runs", isDirectory: true) }
    public var logs: URL { home.appendingPathComponent("logs", isDirectory: true) }
    public var daemonInfo: URL { home.appendingPathComponent("daemon.json") }
    public var daemonLock: URL { home.appendingPathComponent("daemon.lock") }
    public var settings: URL { home.appendingPathComponent("settings.json") }

    public func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [home, blobs, runs, logs] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
    }
}

/// Written by the daemon at startup (mode 0600). Clients read it to find the port and the
/// control-API bearer token.
public struct DaemonInfo: Codable, Sendable, Equatable {
    public var pid: Int32
    public var port: Int
    public var controlToken: String
    public var version: String
    public var startedAt: Date

    public init(pid: Int32, port: Int, controlToken: String, version: String, startedAt: Date) {
        self.pid = pid
        self.port = port
        self.controlToken = controlToken
        self.version = version
        self.startedAt = startedAt
    }

    public static func read(from url: URL) -> DaemonInfo? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? DioramaCoding.decoder.decode(DaemonInfo.self, from: data)
    }

    public func write(to url: URL) throws {
        let data = try DioramaCoding.encoder.encode(self)
        let tmp = url.appendingPathExtension("tmp-\(ProcessInfo.processInfo.processIdentifier)")
        FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600])
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public var controlBaseURL: URL { URL(string: "http://127.0.0.1:\(port)/api/v1")! }
}

// MARK: - Coding

public enum DioramaCoding {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601WithFractions
        e.outputFormatting = [.sortedKeys]
        return e
    }

    public static var prettyEncoder: JSONEncoder {
        let e = encoder
        e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return e
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601WithFractions
        return d
    }
}

extension JSONEncoder.DateEncodingStrategy {
    public static var iso8601WithFractions: JSONEncoder.DateEncodingStrategy {
        .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(DateFormatting.string(date))
        }
    }
}

extension JSONDecoder.DateDecodingStrategy {
    public static var iso8601WithFractions: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let d = DateFormatting.date(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "invalid date \(s)")
            }
            return d
        }
    }
}

public enum DateFormatting {
    public static func string(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: true).timeSeparator(.colon).timeZone(separator: .omitted))
    }

    public static func date(_ s: String) -> Date? {
        if let d = try? Date(s, strategy: .iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: true).timeSeparator(.colon).timeZone(separator: .omitted)) {
            return d
        }
        return try? Date(s, strategy: .iso8601)
    }
}

// MARK: - Hashing and identifiers

public enum Hashing {
    public static func sha256Hex(_ bytes: some Sequence<UInt8>) -> String {
        let digest = SHA256.hash(data: Data(bytes))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(_ string: String) -> String { sha256Hex(Array(string.utf8)) }

    /// 128-bit random token, URL-safe hex.
    public static func randomToken(bytes count: Int = 16) -> String {
        var g = SystemRandomNumberGenerator()
        return (0..<count).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &g)) }.joined()
    }

    public static func newId(prefix: String) -> String {
        "\(prefix)_\(randomToken(bytes: 10))"
    }

    /// Constant-time comparison for secrets.
    public static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}

// MARK: - Pricing

/// Per-million-token list prices used for rewrite-agent cost accounting and estimates.
/// Prices change; the table carries its date and can be overridden in settings later.
public enum Pricing {
    public static let asOf = "2026-10-06"

    public struct ModelPrice: Sendable {
        public let input: Double
        public let output: Double
        public let cacheRead: Double
        public let cacheWrite: Double
        /// Prices above this prompt size (Haiku 5.5 long-context tier).
        public let longContextThreshold: Int?
        public let longInput: Double?
        public let longOutput: Double?
    }

    public static let table: [String: ModelPrice] = [
        "claude-haiku-5-5": .init(input: 0.10, output: 0.50, cacheRead: 0.01, cacheWrite: 0.125, longContextThreshold: 100_000, longInput: 0.50, longOutput: 2.50),
        "claude-sonnet-5-5": .init(input: 2.00, output: 10.00, cacheRead: 0.20, cacheWrite: 2.50, longContextThreshold: nil, longInput: nil, longOutput: nil),
        "claude-opus-5-5": .init(input: 4.00, output: 20.00, cacheRead: 0.20, cacheWrite: 5.00, longContextThreshold: nil, longInput: nil, longOutput: nil),
        "claude-fable-5-1": .init(input: 10.00, output: 50.00, cacheRead: 0.25, cacheWrite: 12.50, longContextThreshold: nil, longInput: nil, longOutput: nil),
        "claude-opus-5": .init(input: 5.00, output: 25.00, cacheRead: 0.50, cacheWrite: 6.25, longContextThreshold: nil, longInput: nil, longOutput: nil),
        "claude-sonnet-5": .init(input: 2.00, output: 10.00, cacheRead: 0.20, cacheWrite: 2.50, longContextThreshold: nil, longInput: nil, longOutput: nil),
        "claude-haiku-4-5": .init(input: 1.00, output: 5.00, cacheRead: 0.10, cacheWrite: 1.25, longContextThreshold: nil, longInput: nil, longOutput: nil),
    ]

    public static func price(for model: String) -> ModelPrice? {
        if let p = table[model] { return p }
        // Tolerate provider prefixes / suffixes such as `anthropic.claude-…` or `…[1m]`.
        return table.first(where: { model.contains($0.key) })?.value
    }

    /// Cost in USD for one request's usage, or nil if the model isn't in the table.
    public static func cost(model: String, usage: TokenUsage) -> Double? {
        guard let p = price(for: model) else { return nil }
        let prompt = usage.inputTokens + usage.cacheReadTokens + usage.cacheWriteTokens
        let long = p.longContextThreshold.map { prompt > $0 } ?? false
        let inRate = long ? (p.longInput ?? p.input) : p.input
        let outRate = long ? (p.longOutput ?? p.output) : p.output
        let total = Double(usage.inputTokens) * inRate + Double(usage.outputTokens) * outRate
            + Double(usage.cacheReadTokens) * p.cacheRead + Double(usage.cacheWriteTokens) * p.cacheWrite
        return total / 1_000_000
    }
}

// MARK: - Glob matching

public enum Glob {
    /// Matches `*` (any run of characters) and `?` (one character). Case-sensitive.
    public static func matches(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern), t = Array(text)
        var pi = 0, ti = 0, star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "?" || p[pi] == t[ti] {
                pi += 1
                ti += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi
                mark = ti
                pi += 1
            } else if star >= 0 {
                pi = star + 1
                mark += 1
                ti = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
