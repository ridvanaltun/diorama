import DioramaCore
import Foundation

public enum SpendHistoryText {
    /// A per-day table for the CLI and the MCP server (days with no spending are skipped).
    public static func render(_ h: SpendHistory) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE yyyy-MM-dd"
        func money(_ v: Double) -> String { v == 0 ? "—" : v < 0.01 ? String(format: "$%.4f", v) : String(format: "$%.2f", v) }
        let spent = h.days.filter { $0.totalUSD > 0 || $0.calls > 0 }
        var out = ["Rewrite-agent spending, last \(h.days.count) day(s): \(money(h.totalUSD)) in total" + (spent.isEmpty ? " (nothing spent)" : "")]
        guard !spent.isEmpty else { return out.joined(separator: "\n") }
        out.append(String(format: "%-16@ %10@ %10@ %10@ %10@ %6@", "DAY" as NSString, "TOTAL" as NSString, "SESSIONS" as NSString, "TRIALS" as NSString, "PREVIEWS" as NSString, "CALLS" as NSString))
        for d in spent {
            out.append(String(format: "%-16@ %10@ %10@ %10@ %10@ %6d", f.string(from: d.day) as NSString, money(d.totalUSD) as NSString, money(d.sessionsUSD) as NSString,
                              money(d.trialsUSD) as NSString, money(d.previewsUSD) as NSString, d.calls))
        }
        var byProfile: [String: Double] = [:]
        for d in h.days { for (k, v) in d.byProfile { byProfile[k, default: 0] += v } }
        if !byProfile.isEmpty {
            out.append("")
            out.append("By profile:")
            for (k, v) in byProfile.sorted(by: { $0.value > $1.value }) { out.append("  \(k): \(money(v))") }
        }
        return out.joined(separator: "\n")
    }
}
