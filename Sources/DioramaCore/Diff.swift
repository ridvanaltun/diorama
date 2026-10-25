import Foundation

/// Word-level diff used by the rewrite detail view and reports.
public enum TextDiff {
    public enum Op: String, Codable, Sendable { case equal, insert, delete }

    public struct Segment: Codable, Sendable, Hashable {
        public var op: Op
        public var text: String
        public init(op: Op, text: String) {
            self.op = op
            self.text = text
        }
    }

    /// Splits text into words and the whitespace/punctuation runs between them, so that
    /// concatenating tokens reproduces the input exactly.
    public static func tokenize(_ s: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var currentIsWord: Bool?
        for ch in s {
            let isWord = ch.isLetter || ch.isNumber || ch == "_"
            if let w = currentIsWord, w == isWord, isWord {
                current.append(ch)
            } else {
                if !current.isEmpty { tokens.append(current) }
                current = String(ch)
                currentIsWord = isWord
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Myers O((N+M)·D) diff over word tokens. Falls back to a coarse delete/insert when the
    /// edit distance exceeds `maxEdits` (keeps huge, unrelated texts fast).
    public static func diff(_ a: String, _ b: String, maxEdits: Int = 4000) -> [Segment] {
        if a == b { return a.isEmpty ? [] : [Segment(op: .equal, text: a)] }
        let x = tokenize(a), y = tokenize(b)
        // Trim common prefix/suffix first.
        var prefix = 0
        while prefix < x.count, prefix < y.count, x[prefix] == y[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < x.count - prefix, suffix < y.count - prefix, x[x.count - 1 - suffix] == y[y.count - 1 - suffix] { suffix += 1 }
        let xs = Array(x[prefix..<(x.count - suffix)])
        let ys = Array(y[prefix..<(y.count - suffix)])
        var out: [Segment] = []
        if prefix > 0 { out.append(Segment(op: .equal, text: x[0..<prefix].joined())) }
        out.append(contentsOf: myers(xs, ys, maxEdits: maxEdits))
        if suffix > 0 { out.append(Segment(op: .equal, text: x[(x.count - suffix)...].joined())) }
        return coalesce(out)
    }

    static func myers(_ a: [String], _ b: [String], maxEdits: Int) -> [Segment] {
        let n = a.count, m = b.count
        if n == 0 { return m == 0 ? [] : [Segment(op: .insert, text: b.joined())] }
        if m == 0 { return [Segment(op: .delete, text: a.joined())] }
        let maxD = min(n + m, maxEdits)
        let offset = maxD + 1
        var v = [Int](repeating: 0, count: 2 * maxD + 3)
        var trace: [[Int]] = []
        var found = false
        outer: for d in 0...maxD {
            trace.append(v)
            var k = -d
            while k <= d {
                var xx: Int
                if k == -d || (k != d && v[k - 1 + offset] < v[k + 1 + offset]) {
                    xx = v[k + 1 + offset]
                } else {
                    xx = v[k - 1 + offset] + 1
                }
                var yy = xx - k
                while xx < n, yy < m, a[xx] == b[yy] {
                    xx += 1
                    yy += 1
                }
                v[k + offset] = xx
                if xx >= n, yy >= m {
                    found = true
                    trace.append(v)
                    break outer
                }
                k += 2
            }
        }
        guard found else { return [Segment(op: .delete, text: a.joined()), Segment(op: .insert, text: b.joined())] }
        // Backtrack.
        var segs: [Segment] = []
        var xx = n, yy = m
        for d in stride(from: trace.count - 2, through: 0, by: -1) {
            let vv = trace[d]
            let k = xx - yy
            let prevK: Int
            if k == -d || (k != d && vv[k - 1 + offset] < vv[k + 1 + offset]) {
                prevK = k + 1
            } else {
                prevK = k - 1
            }
            let prevX = vv[prevK + offset]
            let prevY = prevX - prevK
            while xx > prevX, yy > prevY {
                segs.append(Segment(op: .equal, text: a[xx - 1]))
                xx -= 1
                yy -= 1
            }
            if d > 0 {
                if xx == prevX {
                    segs.append(Segment(op: .insert, text: b[yy - 1]))
                    yy -= 1
                } else {
                    segs.append(Segment(op: .delete, text: a[xx - 1]))
                    xx -= 1
                }
            }
        }
        while xx > 0, yy > 0 {
            segs.append(Segment(op: .equal, text: a[xx - 1]))
            xx -= 1
            yy -= 1
        }
        return segs.reversed()
    }

    static func coalesce(_ segs: [Segment]) -> [Segment] {
        var out: [Segment] = []
        for s in segs where !s.text.isEmpty {
            if let last = out.last, last.op == s.op {
                out[out.count - 1].text += s.text
            } else {
                out.append(s)
            }
        }
        return out
    }

    /// Reconstructs (old, new) from segments — used to verify diffs.
    public static func reconstruct(_ segs: [Segment]) -> (String, String) {
        var a = "", b = ""
        for s in segs {
            switch s.op {
            case .equal:
                a += s.text
                b += s.text
            case .delete: a += s.text
            case .insert: b += s.text
            }
        }
        return (a, b)
    }

    /// Unified-style rendering for terminals and Markdown: `[-old-]{+new+}`.
    public static func inline(_ segs: [Segment]) -> String {
        segs.map {
            switch $0.op {
            case .equal: return $0.text
            case .delete: return "[-\($0.text)-]"
            case .insert: return "{+\($0.text)+}"
            }
        }.joined()
    }
}

// MARK: - Statistics

public enum Stats {
    /// Wilson score interval for a binomial proportion (z = 1.96 → 95%).
    public static func wilson(count: Int, total: Int, z: Double = 1.96) -> ProportionStat {
        guard total > 0 else { return ProportionStat(count: 0, total: 0, rate: 0, interval95: Interval(low: 0, high: 1)) }
        let n = Double(total), p = Double(count) / n
        let z2 = z * z
        let denom = 1 + z2 / n
        let center = (p + z2 / (2 * n)) / denom
        let half = z * ((p * (1 - p) / n + z2 / (4 * n * n)).squareRoot()) / denom
        return ProportionStat(count: count, total: total, rate: p, interval95: Interval(low: max(0, center - half), high: min(1, center + half)))
    }

    public static func numeric(_ values: [Double]) -> NumericStat {
        guard !values.isEmpty else { return NumericStat(n: 0, mean: 0, min: 0, max: 0, stdDev: 0) }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.count > 1 ? values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count - 1) : 0
        return NumericStat(n: values.count, mean: mean, min: values.min()!, max: values.max()!, stdDev: variance.squareRoot())
    }
}
