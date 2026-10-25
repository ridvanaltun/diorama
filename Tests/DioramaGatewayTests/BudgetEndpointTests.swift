import DioramaClient
import DioramaCore
import Foundation
import Testing
@testable import DioramaGateway

@Suite struct BudgetEndpointTests {
    @Test func capsGatePaidPreviewsAndShowInTheSummary() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        _ = try await env.client.createProfile(Profile(name: "web", rules: [Rule(name: "Rename", match: RuleMatch(tools: ["WebFetch"]), instructions: "rename")],
                                                       defaults: ProfileDefaults(dailyBudgetUSD: 1)))
        var s = try await env.client.settings()
        s.dailyBudgetUSD = -1
        await #expect(throws: ClientError.self) { _ = try await env.client.saveSettings(s) }
        s.dailyBudgetUSD = 0.5
        _ = try await env.client.saveSettings(s)

        var summary = try await env.client.spend()
        #expect(summary.todayUSD == 0 && summary.dailyBudgetUSD == 0.5 && !summary.isOverBudget)
        #expect(summary.profiles.map(\.name) == ["web"], "profiles with a cap are listed even before they spend")

        // Use the budget up; paid previews are refused, free checks still work.
        env.daemon.store.recordSpend(kind: "playground", profileId: nil, costUSD: 0.6)
        summary = try await env.client.spend()
        #expect(summary.isOverBudget)
        await #expect(throws: ClientError.self) {
            _ = try await env.client.playground(PlaygroundRequest(profileRef: "web", text: "Example Domain", rewrite: true))
        }
        let free = try await env.client.playground(PlaygroundRequest(profileRef: "web", text: "Example Domain"))
        #expect(free.checks.map(\.matches) == [true])

        let launch = try await env.client.createSession(SessionSpec(name: "b", cwd: "/tmp", profile: "web"))
        _ = try await env.post(launch.token, body: sampleBody())
        let tl = try await env.client.timeline(launch.session.id)
        #expect(tl.decisions.first?.reason.hasPrefix("not rewritten: the daily rewrite budget") == true)
        #expect(tl.session.flags.contains("budget-reached"))
        await #expect(throws: ClientError.self) {
            _ = try await env.client.whatIf(WhatIfRequest(sessionId: launch.session.id, profileRef: "web", rewrite: true))
        }
        #expect(try await env.client.whatIf(WhatIfRequest(sessionId: launch.session.id, profileRef: "web")).calls == 1)
    }
}
