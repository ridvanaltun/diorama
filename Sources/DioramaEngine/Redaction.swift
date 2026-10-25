import DioramaCore
import Foundation

/// Masks secrets and other sensitive strings locally, before anything reaches the model or the
/// rewrite agent. Deterministic and free; used by redaction rules.
public enum Redactor {
    /// Named patterns per preset. Kept specific (known key formats) to avoid masking ordinary text.
    static let presetPatterns: [RedactSpec.Preset: [(name: String, pattern: String)]] = [
        .secrets: [
            ("private-key", #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#),
            ("anthropic-key", #"sk-ant-[A-Za-z0-9_\-]{20,}"#),
            ("openai-key", #"sk-(?:proj-)?[A-Za-z0-9_\-]{32,}"#),
            ("aws-access-key", #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#),
            ("github-token", #"\bgh[pousr]_[A-Za-z0-9]{36,}\b"#),
            ("github-token", #"\bgithub_pat_[A-Za-z0-9_]{60,}\b"#),
            ("slack-token", #"\bxox[abposr]-[A-Za-z0-9-]{10,}"#),
            ("stripe-key", #"\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{20,}\b"#),
            ("google-api-key", #"\bAIza[0-9A-Za-z_\-]{35}\b"#),
            ("jwt", #"\beyJ[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#),
            ("bearer-token", #"(?i)(?<=bearer )[A-Za-z0-9._\-~+/]{20,}=*"#),
        ],
        .emails: [("email", #"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b"#)],
        .ipAddresses: [("ip-address", #"\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b"#)],
    ]

    public struct Result: Sendable, Equatable {
        public var texts: [String]
        /// Matches masked, by kind.
        public var counts: [String: Int]
        public var total: Int { counts.values.reduce(0, +) }

        /// "redacted 2 matches (anthropic-key ×1, private-key ×1)".
        public var summary: String {
            let parts = counts.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }
            return "redacted \(total) match\(total == 1 ? "" : "es") (\(parts.joined(separator: ", ")))"
        }
    }

    public static func apply(_ specs: [RedactSpec], to texts: [String]) -> Result {
        var patterns: [(String, NSRegularExpression)] = []
        for spec in specs {
            for preset in spec.presets {
                for (name, p) in presetPatterns[preset] ?? [] {
                    if let r = try? NSRegularExpression(pattern: p) { patterns.append((name, r)) }
                }
            }
            for p in spec.patterns {
                if let r = try? NSRegularExpression(pattern: p) { patterns.append(("custom", r)) }
            }
        }
        var counts: [String: Int] = [:]
        let out = texts.map { text -> String in
            var t = text
            for (name, r) in patterns {
                let range = NSRange(t.startIndex..., in: t)
                let n = r.numberOfMatches(in: t, range: range)
                guard n > 0 else { continue }
                counts[name, default: 0] += n
                t = r.stringByReplacingMatches(in: t, range: range, withTemplate: "[REDACTED:\(name)]")
            }
            return t
        }
        return Result(texts: out, counts: counts)
    }
}
