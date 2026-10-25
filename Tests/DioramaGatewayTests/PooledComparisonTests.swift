import DioramaClient
import DioramaCore
import Foundation
import Testing
@testable import DioramaGateway

@Suite struct PooledComparisonTests {
    @Test func poolsCompletedRunsOfOneExperiment() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        let store = env.daemon.store
        let exp = try await env.client.createExperiment(ExperimentDefinition(
            name: "pool", task: "t", projectPath: FileManager.default.temporaryDirectory.path,
            variants: [ExperimentVariant(key: "control", name: "c"), ExperimentVariant(key: "s", name: "s", prompt: SessionPrompt(text: "p"))], trialsPerVariant: 2))
        await #expect(throws: ClientError.self) { _ = try await env.client.pooledComparison(experimentId: exp.id) }

        func run(turnsControl: Int, turnsSteered: Int) throws -> RunSummary {
            let est = CostEstimate(trials: 4, perTrialLowUSD: 0, perTrialHighUSD: 0, rewriteLowUSD: 0, rewriteHighUSD: 0, basis: "test", notes: [], confirmationToken: "t")
            let r = try store.createRun(experimentId: exp.id, seed: 1, estimate: est, trials: [("control", 0, 0), ("control", 1, 1), ("s", 0, 2), ("s", 1, 3)])
            for t in try store.trials(runId: r.id) {
                let turns = t.variantKey == "control" ? turnsControl : turnsSteered
                let f = TrialFacts(finalOutput: "o", isError: false, exitCode: 0, durationMs: 1000, numTurns: turns + t.index, toolCalls: [:], rewritesApplied: 0,
                                   rewriteFailures: 0, usage: TokenUsage(), claudeCostUSD: 0.01, rewriteCostUSD: 0, filesChanged: [])
                try store.trialFinished(id: t.id, status: .succeeded, facts: f, signals: nil, error: nil, transcriptBlob: nil)
            }
            try store.setRunStatus(id: r.id, .completed)
            return r
        }
        let r1 = try run(turnsControl: 3, turnsSteered: 6)
        let r2 = try run(turnsControl: 3, turnsSteered: 6)

        let pooled = try await env.client.pooledComparison(experimentId: exp.id)
        #expect(Set(pooled.pooledRunIds ?? []) == [r1.id, r2.id])
        #expect(pooled.trials.count == 8)
        #expect(pooled.variants.map(\.validTrials) == [4, 4])
        #expect(pooled.caveats.first?.hasPrefix("Pooled 2 runs") == true)
        #expect(pooled.differences?.first?.metrics.first { $0.metric == "turns" }?.estimate == 3)
        let one = try await env.client.pooledComparison(experimentId: exp.id, runIds: [r1.id])
        #expect(one.trials.count == 4)
        let md = try await env.client.pooledReport(experimentId: exp.id, format: "md")
        #expect(md.contains("Runs pooled:") && md.contains("Differences vs control"))
        await #expect(throws: ClientError.self) { _ = try await env.client.pooledComparison(experimentId: exp.id, runIds: ["run_other"]) }
    }
}
