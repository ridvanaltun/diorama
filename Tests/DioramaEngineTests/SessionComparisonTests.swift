import DioramaCore
import Foundation
import Testing

@Suite struct SessionComparisonTests {
    func info(_ id: String, hook: Bool = false, rewrites: Int = 0, cost: Double = 0) -> SessionInfo {
        var stats = SessionStats()
        stats.rewrites = rewrites
        stats.rewriteCostUSD = cost
        stats.exchanges = hook ? 0 : 2
        return SessionInfo(id: id, name: id, cwd: "/p", kind: .interactive, status: .ended, createdAt: Date(timeIntervalSince1970: 0),
                           endedAt: Date(timeIntervalSince1970: 90), profileId: nil, profileName: nil, profileVersionId: nil, profileVersionNumber: nil,
                           prompt: nil, lockdown: .none, trialId: nil, claudeSessionIds: [], flags: [], stats: stats, via: hook ? .hook : .gateway)
    }

    func decision(_ id: String, _ tool: String, _ outcome: DecisionOutcome, rule: String? = nil) -> DecisionSummary {
        DecisionSummary(toolUseId: id, sessionId: "s", exchangeId: 1, toolName: tool, outcome: outcome, reason: "", createdAt: Date(timeIntervalSince1970: 10),
                        rules: rule.map { [RuleRef(ruleId: $0, name: $0, ruleHash: "h", profileVersionId: nil)] } ?? [], replayCount: 0, toolInput: nil)
    }

    @Test func comparesCountsToolsRulesAndAnswers() {
        let a = Timeline(session: info("a"), exchanges: [], decisions: [decision("t1", "WebFetch", .unchanged), decision("page:t1", "WebFetch", .unchanged)], events: [])
        let b = Timeline(session: info("b", hook: true, rewrites: 1, cost: 0.02), exchanges: [],
                         decisions: [decision("t2", "WebFetch", .rewritten, rule: "Rename"), decision("t3", "Bash", .unchanged)], events: [])
        let c = SessionComparison.make(a, b)
        #expect(c.metrics.first { $0.label == "Duration" }?.a == 90)
        let results = c.metrics.first { $0.label == "Tool results" }
        #expect(results?.a == 1 && results?.b == 2, "page decisions aren't extra tool results")
        #expect(c.metrics.first { $0.label == "Model requests" }?.b == nil, "hook sessions have no requests")
        #expect(c.tools.map(\.tool) == ["WebFetch", "Bash"] && c.tools[0].a == 1 && c.tools[0].b == 1)
        #expect(c.rulesA.isEmpty && c.rulesB == ["Rename"])
        #expect(c.finalAnswerA == nil)
        #expect(c.text.contains("Rules that rewrote: A none; B Rename"))
    }
}
