import DioramaCore
import Foundation

public enum ProfileTestsText {
    /// Plain text for the CLI and the MCP server.
    public static func render(_ results: [ProfileTestResult], profileName: String) -> String {
        guard !results.isEmpty else { return "“\(profileName)” has no rule tests." }
        let failed = results.filter { !$0.passed }
        var out = ["\(results.count - failed.count) of \(results.count) rule test(s) passed for “\(profileName)”."]
        for r in results {
            out.append("\(r.passed ? "✓" : "✗") \(r.name)" + (r.matched.isEmpty ? " (no rule matches)" : " (matches: \(r.matched.joined(separator: ", ")))"))
            out += r.problems.map { "    \($0)" }
        }
        return out.joined(separator: "\n")
    }
}
