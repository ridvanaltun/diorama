import DioramaClient
import DioramaCore
import Foundation
import Testing
@testable import DioramaStore

@Suite struct RuleStatsTests {
    @Test func countsMatchesOutcomesAndRulesFromOlderVersions() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        let rename = Rule(name: "Rename", match: RuleMatch(tools: ["WebFetch"]), instructions: "rename")
        let docs = Rule(name: "Docs only", match: RuleMatch(tools: ["WebFetch"], content: "Example"), instructions: "docs")
        let never = Rule(name: "Never", match: RuleMatch(tools: ["WebFetch"], content: "zzz-never"), instructions: "never")
        let created = try await env.client.createProfile(Profile(name: "web", rules: [rename, docs, never]))
        let launch = try await env.client.createSession(SessionSpec(name: "s", cwd: "/tmp", profile: "web"))
        _ = try await env.post(launch.token, body: sampleBody(results: [("toolu_s1", "Example Domain page")]))
        _ = try await env.post(launch.token, body: sampleBody(results: [("toolu_s2", "plain page")]))
        // v2 drops "Docs only": its earlier match still counts, marked as an older-version rule.
        _ = try await env.client.updateProfile("web", Profile(name: "web", rules: [rename, never]))
        let second = try await env.client.createSession(SessionSpec(name: "s2", cwd: "/tmp", profile: "web"))
        _ = try await env.post(second.token, body: sampleBody(results: [("toolu_s3", "Example Domain again")]))
        let trial = try await env.client.createSession(SessionSpec(name: "t", cwd: "/tmp", profile: "web", kind: .trial, trialId: "tri_x"))
        _ = try await env.post(trial.token, body: sampleBody(results: [("toolu_t1", "Example Domain trial")]))

        let stats = try await env.client.ruleStats("web")
        #expect(stats.profileId == created.profileId && stats.toolResults == 3 && !stats.includesTrials)
        #expect(stats.rules.map(\.name) == ["Rename", "Never", "Docs only"])
        let r = stats.rules[0]
        #expect(r.inCurrentVersion && r.matched == 3 && r.rewritten == 2 && r.unchanged == 1 && r.failed == 0)
        #expect(r.shared == 1 && r.sessions == 2 && r.lastMatchedAt != nil)
        #expect(stats.rules[1].matched == 0 && stats.rules[1].inCurrentVersion)
        let old = stats.rules[2]
        #expect(!old.inCurrentVersion && old.matched == 1 && old.rewritten == 1 && old.shared == 1)

        let withTrials = try await env.client.ruleStats(created.profileId, days: 0, includeTrials: true)
        #expect(withTrials.toolResults == 4 && withTrials.rules[0].matched == 4 && withTrials.since == nil)
        #expect(stats.text.contains("Never\n  never matched"))
        #expect(stats.text.contains("Docs only (not in the current version)"))
        await #expect(throws: (any Error).self) { try await env.client.ruleStats("nope") }
    }

    @Test func readsClassifierVerdicts() {
        let lines = ["[Prices] Raise prices", "[Prices] Classifier “Does it state a price?”: yes — $20", "[Other] Classifier “Q?”: failed (timeout)"]
        #expect(Store.classifierVerdict(lines, ruleName: "Prices") == true)
        #expect(Store.classifierVerdict(lines, ruleName: "Other") == false)
        #expect(Store.classifierVerdict(lines, ruleName: "None") == nil)
    }
}
