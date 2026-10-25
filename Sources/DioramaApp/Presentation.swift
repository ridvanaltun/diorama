import DioramaCore
import Foundation

/// Human-friendly formatting shared by the app's views (pure, unit-tested).
enum Fmt {
    static func money(_ d: Double?) -> String {
        guard let d else { return "—" }
        if d == 0 { return "$0" }
        if d < 0.001 { return "<$0.001" }
        if d < 1 { return String(format: "$%.3f", d) }
        return String(format: "$%.2f", d)
    }

    /// "$0.010–$0.050", or one value when both ends round the same ("<$0.001").
    /// A sample share: 0.3 → "30%".
    static func share(_ v: Double) -> String {
        let p = v * 100
        return p == p.rounded() ? "\(Int(p))%" : String(format: "%.1f%%", p)
    }

    static func moneyRange(_ low: Double, _ high: Double) -> String {
        let (a, b) = (money(low), money(high))
        return a == b ? a : "\(a)–\(b)"
    }

    static func plural(_ n: Int, _ word: String, _ pluralWord: String? = nil) -> String {
        "\(n) \(n == 1 ? word : (pluralWord ?? word + "s"))"
    }

    static func duration(_ ms: Double?) -> String {
        guard let ms else { return "—" }
        if ms < 1000 { return "\(Int(ms.rounded())) ms" }
        if ms < 60_000 { return String(format: "%.1f s", ms / 1000) }
        return String(format: "%d min %d s", Int(ms / 60_000), Int(ms / 1000) % 60)
    }

    static func tokens(_ n: Int) -> String {
        n >= 10_000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }

    /// Mean, with the spread only when it carries information.
    static func stat(_ s: NumericStat, decimals: Int = 1, money: Bool = false) -> String {
        guard s.n > 0 else { return "—" }
        let fmt = { (v: Double) -> String in money ? Fmt.money(v) : String(format: "%.\(decimals)f", v) }
        // A spread below what the format can show is noise ("<$0.001 ± <$0.001").
        let visible = money ? s.stdDev >= 0.001 && s.mean >= 0.001 : s.stdDev >= 0.5 * pow(10, Double(-decimals))
        if s.n > 1 && visible { return "\(fmt(s.mean)) ± \(fmt(s.stdDev))" }
        // Whole numbers without a spread read better as integers ("3", not "3.0").
        if !money, s.mean == s.mean.rounded(), abs(s.mean) < 1e9 { return String(Int(s.mean)) }
        return fmt(s.mean)
    }

    static func proportion(_ p: ProportionStat) -> String {
        guard p.total > 0 else { return "—" }
        return "\(p.count)/\(p.total)"
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: now)
    }

    /// "Oct 25, 14:02", with the year only when it isn't the current one.
    static func runTitle(_ date: Date, now: Date = Date()) -> String {
        let sameYear = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: now)
        return date.formatted(sameYear ? .dateTime.month(.abbreviated).day().hour().minute() : .dateTime.year().month(.abbreviated).day().hour().minute())
    }

    static func shortPath(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    /// What a tool call was about, in a few words: `WebFetch` + url → "example.com/docs".
    static func toolTarget(_ name: String?, _ inputJSON: String?) -> String? {
        guard let inputJSON, let data = inputJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        func s(_ k: String) -> String? { (obj[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        switch name {
        case "WebFetch":
            guard let url = s("url"), let u = URL(string: url) else { return s("url") }
            let path = u.path == "/" ? "" : u.path
            return (u.host ?? url) + path
        case "WebSearch": return s("query").map { "“\($0)”" }
        case "Read", "Write", "Edit", "NotebookEdit": return s("file_path").map { ($0 as NSString).lastPathComponent }
        case "Bash": return s("command").map { $0.count > 70 ? String($0.prefix(70)) + "…" : $0 }
        case "Grep", "Glob": return s("pattern").map { "“\($0)”" }
        default:
            // MCP and other tools: the first short string argument.
            let first = obj.keys.sorted().compactMap { obj[$0] as? String }.first { !$0.isEmpty && $0.count < 120 }
            return first
        }
    }

    static func toolIcon(_ name: String?) -> String {
        switch name ?? "" {
        case "WebFetch", "WebFetch (page)": return "globe"
        case "WebSearch": return "magnifyingglass"
        case "Read": return "doc.text"
        case "Write", "Edit", "NotebookEdit": return "square.and.pencil"
        case "Bash": return "terminal"
        case "Grep", "Glob": return "text.magnifyingglass"
        case let n where n.hasPrefix("mcp__"): return "puzzlepiece.extension"
        default: return "wrench.and.screwdriver"
        }
    }

    /// `mcp__docs__fetch` → "docs · fetch".
    static func toolName(_ name: String?) -> String {
        guard let name else { return "Tool" }
        if name.hasPrefix("mcp__") {
            let parts = name.dropFirst(5).split(separator: "_", omittingEmptySubsequences: true)
            if parts.count >= 2 { return "\(parts[0]) · \(parts.dropFirst().joined(separator: "_"))" }
        }
        return name
    }
}

/// Groups a session's exchanges into turns: each main/subagent request with the tool results
/// it carried and Claude's response, plus the background requests (WebFetch summarizer,
/// titles, token counts) that happened during it.
enum TimelineLogic {
    struct Turn: Identifiable, Equatable {
        var exchange: ExchangeSummary
        var number: Int
        var background: [ExchangeSummary]
        var id: Int64 { exchange.id }

        /// Tool results first seen in this request (replays are hidden by default).
        func newResults(includeReplays: Bool) -> [ToolResultEntry] {
            exchange.toolResults.filter { includeReplays || $0.handling.isNewDecision }
        }
    }

    static func isTurn(_ e: ExchangeSummary) -> Bool {
        guard e.method == "POST", e.path == "/v1/messages" else { return false }
        // Without hint headers every request is unlabeled; treat requests with tools/results as turns.
        switch e.requestClass {
        case "main", "subagent": return true
        case nil: return !e.toolResults.isEmpty || !(e.assistant?.toolUses.isEmpty ?? true)
        default: return false
        }
    }

    static func turns(_ exchanges: [ExchangeSummary]) -> (turns: [Turn], leading: [ExchangeSummary]) {
        var turns: [Turn] = []
        var leading: [ExchangeSummary] = []
        for e in exchanges.sorted(by: { $0.id < $1.id }) {
            if isTurn(e) {
                turns.append(Turn(exchange: e, number: turns.count + 1, background: []))
            } else if turns.isEmpty {
                leading.append(e)
            } else {
                turns[turns.count - 1].background.append(e)
            }
        }
        return (turns, leading)
    }

    /// Short label for a background request.
    static func backgroundLabel(_ e: ExchangeSummary) -> String {
        if e.path.hasPrefix("/v1/messages/count_tokens") { return "Token count" }
        if e.path == "/v1/messages" {
            if e.toolResults.contains(where: { $0.toolName == "WebFetch (page)" }) { return "WebFetch summarizer (page edited)" }
            switch e.requestClass {
            case "auxiliary": return "Background model call"
            case "compaction": return "Conversation compaction"
            default: return "Model call"
            }
        }
        return "\(e.method) \(e.path)"
    }

    /// Share of the prompt served from cache, when usage is known.
    static func cacheHitRate(_ u: TokenUsage?) -> Double? {
        guard let u else { return nil }
        let prompt = u.inputTokens + u.cacheReadTokens + u.cacheWriteTokens
        return prompt > 0 ? Double(u.cacheReadTokens) / Double(prompt) : nil
    }
}
