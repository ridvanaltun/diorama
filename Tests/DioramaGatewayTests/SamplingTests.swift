import DioramaClient
import DioramaCore
import DioramaEngine
import DioramaJSON
import Foundation
import Testing

@Suite struct SamplingTests {
    @Test func samplePointsAreStableEvenAndIndependentPerRule() {
        let ids = (0..<4000).map { "toolu_\($0)" }
        #expect(RuleMatcher.samplePoint(ruleId: "r", id: "toolu_1") == RuleMatcher.samplePoint(ruleId: "r", id: "toolu_1"))
        let inA = ids.filter { RuleMatcher.samplePoint(ruleId: "a", id: $0) < 0.3 }
        #expect(abs(Double(inA.count) / 4000 - 0.3) < 0.03, "\(inA.count)")
        let inBoth = inA.filter { RuleMatcher.samplePoint(ruleId: "b", id: $0) < 0.3 }
        #expect(abs(Double(inBoth.count) / Double(inA.count) - 0.3) < 0.05, "rules sample independently: \(inBoth.count)")
        #expect(ids.allSatisfy { (0..<1).contains(RuleMatcher.samplePoint(ruleId: "a", id: $0)) })
        #expect(RuleMatcher.percent(0.3) == "30%" && RuleMatcher.percent(0.125) == "12.5%")
    }

    @Test func sampledRulesSkipSomeResultsAndExplainWhy() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        let rule = Rule(id: "half", name: "Half", match: RuleMatch(tools: ["WebFetch"], sample: 0.5), instructions: "rename")
        _ = try await env.client.createProfile(Profile(name: "sampled", rules: [rule]))
        let launch = try await env.client.createSession(SessionSpec(name: "s", cwd: "/tmp", profile: "sampled"))
        let results = (0..<20).map { (id: "toolu_s\($0)", text: "Example Domain \($0)") }
        _ = try await env.post(launch.token, body: sampleBody(results: results))
        var rewritten = 0
        for r in results {
            let d = try await env.client.decision(r.id)
            let inSample = RuleMatcher.samplePoint(ruleId: "half", id: r.id) < 0.5
            #expect((d.summary.outcome == .rewritten) == inSample)
            if !inSample { #expect(d.summary.reason == "not in the sample of “Half” (50%)") }
            if inSample { rewritten += 1 }
        }
        #expect(rewritten > 0 && rewritten < 20)

        // The playground on a recorded result agrees with the session; on pasted text it explains sampling.
        let out = try #require(results.first { RuleMatcher.samplePoint(ruleId: "half", id: $0.id) >= 0.5 })
        let check = try await env.client.playground(PlaygroundRequest(profileRef: "sampled", toolUseId: out.id))
        #expect(check.checks[0].reason == "this tool result isn't in the rule's 50% sample")
        let pasted = try await env.client.playground(PlaygroundRequest(profileRef: "sampled", text: "Example Domain", toolName: "WebFetch"))
        #expect(pasted.checks[0].matches && pasted.checks[0].reason.contains("applies to 50% of such tool results"))

        await #expect(throws: ClientError.self) {
            try await env.client.createProfile(Profile(name: "bad", rules: [Rule(name: "x", match: RuleMatch(tools: ["*"], sample: 1.5), instructions: "x")]))
        }
    }
}

@Suite struct ModelComparisonTests {
    @Test func runsTheSameRewriteOnEachModel() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        _ = try await env.client.createProfile(Profile(name: "web", rules: [Rule(name: "Rename", match: RuleMatch(tools: ["WebFetch"]), instructions: "rename")]))
        let models = ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-opus-5-5"]
        let r = try await env.client.playground(PlaygroundRequest(profileRef: "web", text: "Example Domain", toolName: "WebFetch", rewrite: true, models: models))
        let all = try #require(r.comparisons)
        #expect(all.map(\.model) == ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5"], "in order, duplicates removed")
        #expect(all.allSatisfy { $0.status == .succeeded && $0.replacementText == "Morph Test Domain" })
        #expect(r.rewrite?.model == "claude-haiku-5-5")

        let none = try await env.client.playground(PlaygroundRequest(profileRef: "web", text: "x", toolName: "Bash", rewrite: true, models: ["a", "b"]))
        #expect(none.comparisons == nil && none.note != nil, "nothing matches: no calls")
        await #expect(throws: ClientError.self) {
            try await env.client.playground(PlaygroundRequest(profileRef: "web", text: "Example", toolName: "WebFetch", rewrite: true, models: ["a", "b", "c", "d", "e"]))
        }
    }
}
