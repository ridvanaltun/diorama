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

@Suite struct ReplacementRuleTests {
    let replace = Rule(id: "rep", name: "Temperature", match: RuleMatch(tools: ["WebFetch"]), instructions: "",
                       replace: [Replacement(find: "30 derece", with: "5 derece")])

    @Test func replacesWithoutTheRewriteAgent() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        _ = try await env.client.createProfile(Profile(name: "temp", rules: [replace]))
        let s = try await env.client.createSession(SessionSpec(name: "s", cwd: "/tmp", profile: "temp"))
        _ = try await env.post(s.token, body: sampleBody(results: [("toolu_rp1", "Bugün 30 derece, yarın 30 derece.")]))
        let d = try await env.client.decision("toolu_rp1")
        #expect(d.summary.outcome == .rewritten && d.replacementText == "Bugün 5 derece, yarın 5 derece.")
        #expect(d.summary.reason == "replaced “30 derece” → “5 derece” ×2")
        #expect(d.attempts.isEmpty, "no model call")
        #expect(d.instructions == ["[Temperature] Replace “30 derece” → “5 derece” (local, no AI)"])
        let forwarded = String(decoding: try #require(env.mock.requests.last).body, as: UTF8.self)
        #expect(forwarded.contains("5 derece") && !forwarded.contains("30 derece"))
    }

    @Test func aiRulesSeeTheReplacedText() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        let ai = Rule(id: "ai", name: "Rename", match: RuleMatch(tools: ["WebFetch"]), instructions: "rename")
        _ = try await env.client.createProfile(Profile(name: "both", rules: [replace, ai]))
        let s = try await env.client.createSession(SessionSpec(name: "s", cwd: "/tmp", profile: "both"))
        _ = try await env.post(s.token, body: sampleBody(results: [("toolu_rp2", "Example Domain: 30 derece")]))
        let d = try await env.client.decision("toolu_rp2")
        #expect(d.replacementText == "Morph Test Domain: 5 derece")
        #expect(d.summary.reason.hasPrefix("replaced “30 derece” → “5 derece” ×1; "))
    }

    @Test func pauseAndShadowStopReplacementsButNotRedaction() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        let redact = Rule(id: "red", name: "Secrets", match: RuleMatch(tools: ["*"]), instructions: "", redact: RedactSpec(presets: [], patterns: ["tok-[0-9]+"]))
        _ = try await env.client.createProfile(Profile(name: "p", rules: [redact, replace]))
        let s = try await env.client.createSession(SessionSpec(name: "s", cwd: "/tmp", profile: "p"))
        _ = try await env.client.setPaused(s.session.id, true)
        _ = try await env.post(s.token, body: sampleBody(results: [("toolu_rp3", "tok-1 and 30 derece")]))
        let paused = try await env.client.decision("toolu_rp3")
        #expect(paused.replacementText == "[REDACTED:custom] and 30 derece" && paused.summary.reason.contains("not replaced: steering is paused for this session"))

        _ = try await env.client.createProfile(Profile(name: "shadow", rules: [replace], defaults: ProfileDefaults(shadow: true)))
        let sh = try await env.client.createSession(SessionSpec(name: "sh", cwd: "/tmp", profile: "shadow"))
        _ = try await env.post(sh.token, body: sampleBody(results: [("toolu_rp4", "30 derece")]))
        let shadow = try await env.client.decision("toolu_rp4")
        #expect(shadow.summary.outcome == .unchanged && shadow.shadowText == "5 derece" && shadow.summary.reason.hasPrefix("shadow mode, would have replaced"))
    }

    @Test func validatesReplacements() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        for bad in [[Replacement(find: "", with: "x")], [], [Replacement(find: "(", with: "x", regex: true)]] {
            await #expect(throws: ClientError.self) {
                try await env.client.createProfile(Profile(name: "bad", rules: [Rule(name: "r", match: RuleMatch(tools: ["*"]), instructions: "", replace: bad)]))
            }
        }
        var withClassifier = replace
        withClassifier.match.classifier = RuleClassifier(question: "q?")
        await #expect(throws: ClientError.self) { try await env.client.createProfile(Profile(name: "bad2", rules: [withClassifier])) }
    }
}
