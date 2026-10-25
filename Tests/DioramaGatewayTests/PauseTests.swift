import DioramaClient
import DioramaCore
import DioramaEngine
import Foundation
import Testing
@testable import DioramaGateway

@Suite struct PauseTests {
    let rules = [
        Rule(name: "Redact", match: RuleMatch(tools: ["*"]), instructions: "", redact: RedactSpec()),
        Rule(name: "Rename", match: RuleMatch(tools: ["WebFetch"]), instructions: "rename"),
    ]
    let secret = "sk-ant-api03-" + String(repeating: "p", count: 40)

    @Test func pausedSessionsForwardUnchangedButStillRedact() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        _ = try await env.client.createProfile(Profile(name: "web", rules: rules))
        let launch = try await env.client.createSession(SessionSpec(name: "p", cwd: "/tmp", profile: "web"))
        let paused = try await env.client.setPaused(launch.session.id, true)
        #expect(paused.isPaused)

        let (_, _, forwarded1) = try await env.post(launch.token, body: sampleBody(results: [("toolu_p1", "Example Domain \(secret)")]))
        _ = forwarded1
        let d1 = try #require(try await env.client.decision("toolu_p1"))
        #expect(d1.summary.outcome == .rewritten, "redaction still applies")
        #expect(d1.summary.reason.contains("steering is paused for this session"))
        #expect(d1.replacementText?.contains("Example Domain") == true, "no AI rewrite while paused")
        #expect(d1.replacementText?.contains(secret) == false)
        #expect(try await env.client.timeline(launch.session.id).events.contains { $0.message.hasPrefix("Steering paused") })

        _ = try await env.client.setPaused(launch.session.id, false)
        _ = try await env.post(launch.token, body: sampleBody(results: [("toolu_p2", "Example Domain page")]))
        #expect(try await env.client.decision("toolu_p2").replacementText == "Morph Test Domain page")
    }

    @Test func globalPauseSurvivesSettingsSavesAndSparesTrials() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        _ = try await env.client.createProfile(Profile(name: "web", rules: [Rule(name: "Rename", match: RuleMatch(tools: ["WebFetch"]), instructions: "rename")]))
        var settings = try await env.client.setSteeringPaused(true)
        #expect(settings.steeringPaused)
        // An older draft saved from Settings doesn't undo the pause.
        settings.steeringPaused = false
        settings.retentionDays = 30
        let saved = try await env.client.saveSettings(settings)
        #expect(saved.steeringPaused && saved.retentionDays == 30)

        let launch = try await env.client.createSession(SessionSpec(name: "g", cwd: "/tmp", profile: "web"))
        _ = try await env.post(launch.token, body: sampleBody(results: [("toolu_g1", "Example Domain page")]))
        #expect(try await env.client.decision("toolu_g1").summary.reason == "not rewritten: steering is paused everywhere")

        let trial = try await env.client.createSession(SessionSpec(name: "t", cwd: "/tmp", profile: "web", kind: .trial, trialId: "tri_x"))
        _ = try await env.post(trial.token, body: sampleBody(results: [("toolu_t1", "Example Domain page")]))
        #expect(try await env.client.decision("toolu_t1").summary.outcome == .rewritten, "experiment trials aren't paused")

        _ = try await env.client.setSteeringPaused(false)
        _ = try await env.post(launch.token, body: sampleBody(results: [("toolu_g2", "Example Domain page")]))
        #expect(try await env.client.decision("toolu_g2").summary.outcome == .rewritten)
    }
}
