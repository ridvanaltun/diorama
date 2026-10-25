import DioramaCore
import Foundation
import Testing
@testable import DioramaRunner

@Suite struct DifferenceStatsTests {
    @Test func newcombeMatchesThePublishedExample() throws {
        // Newcombe (1998), method 10: 56/70 vs 48/80 → 0.2000 (0.0524 to 0.3339).
        let d = try #require(Stats.proportionDifference(Stats.wilson(count: 48, total: 80), Stats.wilson(count: 56, total: 70)))
        #expect(abs(d.estimate - 0.2) < 1e-9)
        #expect(abs(d.interval95.low - 0.0524) < 0.0005)
        #expect(abs(d.interval95.high - 0.3339) < 0.0005)
        // Extreme, small samples stay inside [-1, 1] and still separate 0/10 from 10/10.
        let e = try #require(Stats.proportionDifference(Stats.wilson(count: 0, total: 10), Stats.wilson(count: 10, total: 10)))
        #expect(e.estimate == 1 && e.interval95.high <= 1 && e.interval95.low > 0.5)
        #expect(Stats.proportionDifference(Stats.wilson(count: 0, total: 0), Stats.wilson(count: 1, total: 2)) == nil)
    }

    @Test func welchIntervals() throws {
        #expect(abs(Stats.tQuantile975(10) - 2.228) < 1e-9)
        #expect(abs(Stats.tQuantile975(18) - 2.101) < 0.005)
        #expect(Stats.tQuantile975(0.5) == 12.706)
        #expect(abs(Stats.tQuantile975(5_000_000) - 1.96) < 1e-9)
        // n = 10 each, sd 1, means 0 and 1: se = √0.2, df = 18.
        let a = NumericStat(n: 10, mean: 0, min: -2, max: 2, stdDev: 1), b = NumericStat(n: 10, mean: 1, min: -1, max: 3, stdDev: 1)
        let d = try #require(Stats.meanDifference(a, b))
        let half = 0.2.squareRoot() * 2.101
        #expect(abs(d.estimate - 1) < 1e-9)
        #expect(abs(d.interval95.low - (1 - half)) < 0.005 && abs(d.interval95.high - (1 + half)) < 0.005)
        #expect(Stats.meanDifference(NumericStat(n: 1, mean: 0, min: 0, max: 0, stdDev: 0), b) == nil, "needs two trials per side")
        let same = try #require(Stats.meanDifference(NumericStat(n: 3, mean: 3, min: 3, max: 3, stdDev: 0), NumericStat(n: 3, mean: 3, min: 3, max: 3, stdDev: 0)))
        #expect(same.interval95.low == 0 && same.interval95.high == 0)
    }

    @Test func comparisonsCarryDifferencesPerVariant() {
        let def = ExperimentDefinition(name: "x", task: "t", projectPath: "/tmp", variants: [
            ExperimentVariant(key: "control", name: "c"), ExperimentVariant(key: "s", name: "s", prompt: SessionPrompt(text: "p")),
        ], trialsPerVariant: 10)
        func trial(_ i: Int, _ v: String, turns: Int, echoed: Bool, tools: [String: Int]) -> TrialInfo {
            let f = TrialFacts(finalOutput: "o\(i)", isError: false, exitCode: 0, durationMs: 1000, numTurns: turns, toolCalls: tools, rewritesApplied: v == "s" ? 1 : 0,
                               rewriteFailures: 0, usage: TokenUsage(inputTokens: 10), claudeCostUSD: 0.01, rewriteCostUSD: 0, filesChanged: [])
            return TrialInfo(id: "\(i)", runId: "r", variantKey: v, index: i, order: i, status: .succeeded, sessionId: nil, workdir: nil, startedAt: nil, finishedAt: nil,
                             manifest: nil, facts: f, signals: TrialSignals(echoedRewrittenContent: echoed, flaggedSuspicion: false, attemptedVerification: false, evidence: []), error: nil)
        }
        let trials = (0..<10).map { trial($0, "control", turns: 3 + $0 % 2, echoed: false, tools: ["WebFetch": 1]) }
            + (10..<20).map { trial($0, "s", turns: 5 + $0 % 2, echoed: true, tools: ["WebFetch": 1, "WebSearch": 1]) }
        let run = RunSummary(id: "r", experimentId: "e", status: .completed, createdAt: Date(), startedAt: nil, finishedAt: nil, seed: 1, trialsTotal: 20, trialsDone: 20, estimate: nil)
        let c = Comparison.compare(run: run, definition: def, trials: trials)
        let d = try! #require(c.differences?.first)
        #expect(d.variantKey == "s" && d.controlKey == "control")
        let byMetric = Dictionary(uniqueKeysWithValues: d.metrics.map { ($0.metric, $0) })
        #expect(byMetric["turns"]?.estimate == 2 && byMetric["turns"]?.excludesZero == true)
        #expect(byMetric["echoedRewrittenContent"]?.isHeuristic == true && byMetric["echoedRewrittenContent"]?.excludesZero == true)
        #expect(byMetric["toolCalls.WebSearch"]?.control == 0, "a tool the control never called counts as zero calls")
        #expect(byMetric["claudeCostUSD"]?.excludesZero == false)
        #expect(byMetric["judgeAdopted"] == nil)
        #expect(c.caveats.contains { $0.contains("one metric at a time") })
    }
}
