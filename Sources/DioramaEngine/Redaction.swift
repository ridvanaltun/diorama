import DioramaCore
import Foundation

/// Masks secrets and other sensitive strings, and applies replacement rules, locally: before
/// anything reaches the model or the rewrite agent. Deterministic and free.
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
        /// Replacements made, by replacement (its summary).
        public var replaced: [String: Int] = [:]
        public var total: Int { counts.values.reduce(0, +) + replaced.values.reduce(0, +) }

        /// "redacted 2 matches (anthropic-key ×1, private-key ×1); replaced “30 derece” → “5 derece” ×2".
        public var summary: String {
            var parts: [String] = []
            let masked = counts.values.reduce(0, +)
            if masked > 0 {
                let kinds = counts.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }
                parts.append("redacted \(masked) match\(masked == 1 ? "" : "es") (\(kinds.joined(separator: ", ")))")
            }
            if !replaced.isEmpty {
                parts.append("replaced " + replaced.sorted { $0.key < $1.key }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", "))
            }
            return parts.joined(separator: "; ")
        }
    }

    /// Redaction first (so secrets never reach a replacement or the agent), then replacements in order.
    public static func apply(_ specs: [RedactSpec], replacements: [Replacement] = [], to texts: [String]) -> Result {
        var result = redact(specs, texts)
        for r in replacements {
            guard let re = r.expression else { continue }
            var remaining = r.firstOnly ? 1 : Int.max
            result.texts = result.texts.map { text in
                guard remaining > 0 else { return text }
                let ns = text as NSString
                let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).prefix(remaining)
                guard !matches.isEmpty else { return text }
                remaining -= matches.count
                result.replaced[r.summary, default: 0] += matches.count
                let out = NSMutableString(string: text)
                for m in matches.reversed() {
                    out.replaceCharacters(in: m.range, with: re.replacementString(for: m, in: text, offset: 0, template: r.template))
                }
                return out as String
            }
        }
        return result
    }

    static func redact(_ specs: [RedactSpec], _ texts: [String]) -> Result {
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
