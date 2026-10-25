import DioramaCore
import Foundation

extension ProfileRuleStats {
    /// Plain-text summary for the CLI and the MCP server.
    public var text: String {
        let window = since.map { "since \(Self.day.string(from: $0))" } ?? "all time"
        var out = ["Rule usage for “\(profileName)”, \(window)\(includesTrials ? ", experiment trials included" : ""): "
            + "\(toolResults) tool result(s) matched, \(Self.money(costUSD))"]
        for r in rules {
            out.append("")
            out.append("\(r.name)\(r.inCurrentVersion ? "" : " (not in the current version)")")
            guard r.matched > 0 else {
                out.append("  never matched")
                continue
            }
            var line = "  matched \(r.matched) in \(r.sessions) session(s): \(r.rewritten) rewritten, \(r.unchanged) unchanged, \(r.failed) failed"
            if r.shared > 0 { line += "; \(r.shared) shared with other rules" }
            out.append(line)
            if r.classifierYes + r.classifierNo > 0 { out.append("  classifier: \(r.classifierYes) yes, \(r.classifierNo) no") }
            out.append("  cost \(Self.money(r.costUSD))" + (r.lastMatchedAt.map { ", last matched \(Self.day.string(from: $0))" } ?? ""))
        }
        if rules.contains(where: { $0.shared > 0 }) {
            out.append("")
            out.append("A tool result matched by several rules counts, with its cost, for each of them.")
        }
        return out.joined(separator: "\n")
    }

    static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func money(_ v: Double) -> String { v == 0 ? "$0" : v < 0.01 ? String(format: "$%.4f", v) : String(format: "$%.2f", v) }
}
