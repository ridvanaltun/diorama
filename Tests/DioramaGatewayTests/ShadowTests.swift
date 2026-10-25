import DioramaClient
import DioramaCore
import Foundation
import Testing

@Suite struct ShadowTests {
    @Test func shadowModeRecordsTheRewriteButForwardsTheOriginal() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        _ = try await env.client.createProfile(Profile(
            name: "shadow", rules: [Rule(name: "Rename", match: RuleMatch(tools: ["WebFetch"]), instructions: "rename")], defaults: ProfileDefaults(shadow: true)))
        let launch = try await env.client.createSession(SessionSpec(name: "s", cwd: "/tmp", profile: "shadow"))
        let body = sampleBody(results: [("toolu_sh1", "Example Domain page")])
        _ = try await env.post(launch.token, body: body)
        let forwarded = String(decoding: try #require(env.mock.requests.last).body, as: UTF8.self)
        #expect(forwarded.contains("Example Domain page") && !forwarded.contains("Morph Test Domain"))

        let d = try await env.client.decision("toolu_sh1")
        #expect(d.summary.outcome == .unchanged && d.summary.reason.hasPrefix("shadow mode, would rewrite: "))
        #expect(d.replacementText == nil && d.shadowText == "Morph Test Domain page" && d.attempts.count == 1)

        // Replays keep sending the original.
        _ = try await env.post(launch.token, body: body)
        #expect(!String(decoding: try #require(env.mock.requests.last).body, as: UTF8.self).contains("Morph Test Domain"))
        // Shadow rewrites count as matches in rule usage, and as unchanged.
        let stats = try await env.client.ruleStats("shadow")
        #expect(stats.rules[0].matched == 1 && stats.rules[0].unchanged == 1)
    }

    @Test func trialsIgnoreShadowMode() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        _ = try await env.client.createProfile(Profile(
            name: "shadow", rules: [Rule(name: "Rename", match: RuleMatch(tools: ["WebFetch"]), instructions: "rename")], defaults: ProfileDefaults(shadow: true)))
        let trial = try await env.client.createSession(SessionSpec(name: "t", cwd: "/tmp", profile: "shadow", kind: .trial, trialId: "tri_s"))
        _ = try await env.post(trial.token, body: sampleBody(results: [("toolu_sh2", "Example Domain page")]))
        #expect(try await env.client.decision("toolu_sh2").summary.outcome == .rewritten)
    }
}
