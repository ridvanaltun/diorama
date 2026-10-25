import Foundation

/// Two sessions side by side, built from their timelines: counts, cost, duration, tool usage,
/// rules that changed something, and Claude's final answer.
public struct SessionComparison: Codable, Sendable, Hashable {
    public struct Metric: Codable, Sendable, Hashable, Identifiable {
        public var label: String
        public var a: Double?
        public var b: Double?
        /// How to show the values: "count", "usd", "seconds" or "tokens".
        public var unit: String
        public var id: String { label }
    }

    public struct ToolCount: Codable, Sendable, Hashable, Identifiable {
        public var tool: String
        public var a: Int
        public var b: Int
        public var id: String { tool }
    }

    public var a: SessionInfo
    public var b: SessionInfo
    public var metrics: [Metric]
    public var tools: [ToolCount]
    /// Rules that rewrote at least one result, per session.
    public var rulesA: [String]
    public var rulesB: [String]
    public var finalAnswerA: String?
    public var finalAnswerB: String?

    public static func make(_ x: Timeline, _ y: Timeline) -> SessionComparison {
        func duration(_ t: Timeline) -> Double? {
            let ends = t.exchanges.map { $0.startedAt.addingTimeInterval(($0.durationMs ?? 0) / 1000) } + t.decisions.map(\.createdAt)
            guard let end = t.session.endedAt ?? ends.max() else { return nil }
            return max(0, end.timeIntervalSince(t.session.createdAt))
        }
        func tokens(_ t: Timeline, _ f: (TokenUsage) -> Int) -> Double? {
            t.session.isHook ? nil : Double(t.exchanges.compactMap(\.usage).map(f).reduce(0, +))
        }
        func results(_ t: Timeline) -> [DecisionSummary] { t.decisions.filter { !$0.toolUseId.hasPrefix("page:") && !$0.toolUseId.hasPrefix("input:") } }
        let (sa, sb) = (x.session.stats, y.session.stats)
        var metrics = [
            Metric(label: "Duration", a: duration(x), b: duration(y), unit: "seconds"),
            Metric(label: "Model requests", a: x.session.isHook ? nil : Double(sa.exchanges), b: y.session.isHook ? nil : Double(sb.exchanges), unit: "count"),
            Metric(label: "Tool results", a: Double(results(x).count), b: Double(results(y).count), unit: "count"),
            Metric(label: "Rewritten", a: Double(sa.rewrites), b: Double(sb.rewrites), unit: "count"),
            Metric(label: "Failed rewrites", a: Double(sa.failures), b: Double(sb.failures), unit: "count"),
            Metric(label: "Rewrite cost", a: sa.rewriteCostUSD, b: sb.rewriteCostUSD, unit: "usd"),
            Metric(label: "Input tokens", a: tokens(x, \.inputTokens), b: tokens(y, \.inputTokens), unit: "tokens"),
            Metric(label: "Output tokens", a: tokens(x, \.outputTokens), b: tokens(y, \.outputTokens), unit: "tokens"),
        ]
        metrics = metrics.filter { $0.a != nil || $0.b != nil }

        var counts: [String: (Int, Int)] = [:]
        for d in results(x) { counts[d.toolName ?? "tool", default: (0, 0)].0 += 1 }
        for d in results(y) { counts[d.toolName ?? "tool", default: (0, 0)].1 += 1 }
        let tools = counts.map { ToolCount(tool: $0.key, a: $0.value.0, b: $0.value.1) }
            .sorted { ($0.a + $0.b, $1.tool) > ($1.a + $1.b, $0.tool) }

        func rules(_ t: Timeline) -> [String] {
            var seen: [String] = []
            for d in t.decisions where d.outcome == .rewritten { for r in d.rules where !seen.contains(r.name) { seen.append(r.name) } }
            return seen
        }
        func finalAnswer(_ t: Timeline) -> String? {
            t.exchanges.filter { ($0.requestClass ?? "main") == "main" }.sorted { $0.id < $1.id }
                .last { !($0.assistant?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?.assistant?.text
        }
        return SessionComparison(a: x.session, b: y.session, metrics: metrics, tools: tools, rulesA: rules(x), rulesB: rules(y),
                                 finalAnswerA: finalAnswer(x), finalAnswerB: finalAnswer(y))
    }

    /// Plain text for the CLI and the MCP server.
    public var text: String {
        func v(_ x: Double?, _ unit: String) -> String {
            guard let x else { return "—" }
            switch unit {
            case "usd": return x == 0 ? "$0" : x < 0.01 ? String(format: "$%.4f", x) : String(format: "$%.2f", x)
            case "seconds": return x < 60 ? String(format: "%.0f s", x) : String(format: "%.1f min", x / 60)
            default: return String(Int(x))
            }
        }
        func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }
        var out = ["A: “\(a.name)” (\(a.id))" + (a.profileName.map { ", \($0) v\(a.profileVersionNumber ?? 0)" } ?? ", no profile"),
                   "B: “\(b.name)” (\(b.id))" + (b.profileName.map { ", \($0) v\(b.profileVersionNumber ?? 0)" } ?? ", no profile"), ""]
        out.append(pad("", 18) + pad("A", 12) + "B")
        for m in metrics { out.append(pad(m.label, 18) + pad(v(m.a, m.unit), 12) + v(m.b, m.unit)) }
        if !tools.isEmpty {
            out.append("")
            out.append("Tool results by tool")
            for t in tools { out.append(pad("  " + t.tool, 18) + pad(String(t.a), 12) + String(t.b)) }
        }
        out.append("")
        out.append("Rules that rewrote: A " + (rulesA.isEmpty ? "none" : rulesA.joined(separator: ", ")) + "; B " + (rulesB.isEmpty ? "none" : rulesB.joined(separator: ", ")))
        for (label, answer) in [("A", finalAnswerA), ("B", finalAnswerB)] {
            out.append("")
            out.append("Final answer \(label):")
            out.append(answer.map { $0.count > 1200 ? String($0.prefix(1200)) + "…" : $0 } ?? "(none recorded)")
        }
        return out.joined(separator: "\n")
    }
}
