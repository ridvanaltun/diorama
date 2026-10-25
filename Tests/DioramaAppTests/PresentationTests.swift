import DioramaCore
import Foundation
import Testing
@testable import DioramaApp

@Suite struct PresentationTests {
    @Test func formatsNumbersForPeople() {
        #expect(Fmt.money(nil) == "—")
        #expect(Fmt.money(0) == "$0")
        #expect(Fmt.money(0.0004) == "<$0.001")
        #expect(Fmt.money(0.0123) == "$0.012")
        #expect(Fmt.money(3.456) == "$3.46")
        #expect(Fmt.moneyRange(0.0002, 0.0008) == "<$0.001")
        #expect(Fmt.moneyRange(0.01, 0.05) == "$0.010–$0.050")
        #expect(Fmt.plural(1, "rule") == "1 rule")
        #expect(Fmt.plural(2, "rule") == "2 rules")
        #expect(Fmt.plural(3, "anomaly", "anomalies") == "3 anomalies")
        #expect(Fmt.duration(420) == "420 ms")
        #expect(Fmt.duration(2_500) == "2.5 s")
        #expect(Fmt.duration(125_000) == "2 min 5 s")
        #expect(Fmt.tokens(950) == "950")
        #expect(Fmt.tokens(12_345) == "12.3k")
    }

    @Test func statShowsSpreadOnlyWhenItCarriesInformation() {
        #expect(Fmt.stat(NumericStat(n: 0, mean: 0, min: 0, max: 0, stdDev: 0)) == "—")
        #expect(Fmt.stat(NumericStat(n: 1, mean: 4, min: 4, max: 4, stdDev: 0)) == "4")
        #expect(Fmt.stat(NumericStat(n: 5, mean: 4, min: 4, max: 4, stdDev: 0)) == "4")
        #expect(Fmt.stat(NumericStat(n: 5, mean: 2.5, min: 2.5, max: 2.5, stdDev: 0.01)) == "2.5")
        #expect(Fmt.stat(NumericStat(n: 3, mean: 0.0004, min: 0.0003, max: 0.0005, stdDev: 0.0001), money: true) == "<$0.001")
        #expect(Fmt.stat(NumericStat(n: 5, mean: 4, min: 3, max: 5, stdDev: 0.71)) == "4.0 ± 0.7")
        #expect(Fmt.stat(NumericStat(n: 3, mean: 0.05, min: 0.04, max: 0.06, stdDev: 0.01), money: true) == "$0.050 ± $0.010")
    }

    @Test func summarizesToolTargets() {
        #expect(Fmt.toolTarget("WebFetch", #"{"url":"https://example.com/docs/api?x=1","prompt":"p"}"#) == "example.com/docs/api")
        #expect(Fmt.toolTarget("WebFetch", #"{"url":"https://example.com/"}"#) == "example.com")
        #expect(Fmt.toolTarget("WebSearch", #"{"query":"swift nio"}"#) == "“swift nio”")
        #expect(Fmt.toolTarget("Read", #"{"file_path":"/a/b/Package.swift"}"#) == "Package.swift")
        #expect(Fmt.toolTarget("Bash", "{\"command\":\"" + String(repeating: "x", count: 100) + "\"}")?.count == 71)
        #expect(Fmt.toolTarget("mcp__docs__fetch", #"{"id":"abc"}"#) == "abc")
        #expect(Fmt.toolTarget("Read", "not json") == nil)
        #expect(Fmt.toolTarget("Read", nil) == nil)
        #expect(Fmt.toolName("mcp__docs__fetch_page") == "docs · fetch_page")
        #expect(Fmt.toolName("WebFetch") == "WebFetch")
        #expect(Fmt.toolIcon("mcp__x__y") == "puzzlepiece.extension")
    }

    func exchange(_ id: Int64, path: String = "/v1/messages", cls: String?, results: [ToolResultEntry] = []) -> ExchangeSummary {
        ExchangeSummary(id: id, sessionId: "s", startedAt: Date(), method: "POST", path: path, requestClass: cls, agentId: nil,
                        claudeSessionId: nil, model: nil, status: 200, timeToFirstByteMs: nil, addedLatencyMs: nil,
                        durationMs: nil, usage: nil, toolResults: results, assistant: nil, error: nil)
    }

    @Test func groupsBackgroundRequestsUnderTheirTurn() {
        let page = ToolResultEntry(toolUseId: "page:t1", toolName: "WebFetch (page)", handling: .decidedRewritten)
        let (turns, leading) = TimelineLogic.turns([
            exchange(5, cls: "main"),
            exchange(1, path: "/v1/messages/count_tokens", cls: nil),
            exchange(2, cls: "main"),
            exchange(3, cls: "auxiliary", results: [page]),
            exchange(4, path: "/v1/messages/count_tokens", cls: nil),
        ])
        #expect(leading.map(\.id) == [1])
        #expect(turns.map(\.exchange.id) == [2, 5])
        #expect(turns.map(\.number) == [1, 2])
        #expect(turns[0].background.map(\.id) == [3, 4])
        #expect(TimelineLogic.backgroundLabel(turns[0].background[0]) == "WebFetch summarizer (page edited)")
        #expect(TimelineLogic.backgroundLabel(turns[0].background[1]) == "Token count")
        // Without hint headers, a request carrying tool results still counts as a turn.
        #expect(TimelineLogic.isTurn(exchange(9, cls: nil, results: [page])))
        #expect(!TimelineLogic.isTurn(exchange(9, cls: nil)))
    }

    @Test func cacheHitRate() {
        #expect(TimelineLogic.cacheHitRate(nil) == nil)
        #expect(TimelineLogic.cacheHitRate(TokenUsage()) == nil)
        #expect(TimelineLogic.cacheHitRate(TokenUsage(inputTokens: 10, cacheReadTokens: 90)) == 0.9)
    }

    @Test func flagsRulesThatWouldNeverWork() {
        var rule = Rule(name: "r", match: RuleMatch(tools: ["WebFetch"]), instructions: "Do it")
        #expect(FormLogic.ruleProblems(rule).isEmpty)
        rule.match.tools = []
        rule.instructions = "  "
        rule.match.content = "("
        rule.match.input = ["url": "[a-"]
        #expect(FormLogic.ruleProblems(rule) == [
            "No tools: the rule never matches.", "No instructions for the rewrite agent.",
            "Content regex is invalid.", "Input pattern for “url” is an invalid regex.",
        ])
    }
}

@Suite struct RedactionRuleProblemsTests {
    @Test func flagsEmptyAndInvalidRedactions() {
        var r = Rule(name: "r", match: RuleMatch(tools: ["*"]), instructions: "", redact: RedactSpec(presets: [], patterns: []))
        #expect(FormLogic.ruleProblems(r) == ["Nothing to redact: pick a preset or add a pattern."])
        r.redact = RedactSpec(presets: [.secrets], patterns: ["(bad"])
        #expect(FormLogic.ruleProblems(r) == ["Redaction pattern “(bad” is an invalid regex."])
        r.redact = RedactSpec()
        #expect(FormLogic.ruleProblems(r).isEmpty, "redaction rules need no instructions")
    }
}
