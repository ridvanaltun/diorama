import DioramaClient
import DioramaCore
import Foundation
import Testing
@testable import DioramaEngine

@Suite struct ReviewTests {
    func reviewProfile() -> Profile {
        Profile(name: "reviewed", rules: [Rule(name: "Rename", match: RuleMatch(tools: ["WebFetch"]), instructions: "rename")],
                defaults: ProfileDefaults(review: true, reviewTimeoutSeconds: 30))
    }

    func waitForReview(_ env: TestEnv) async throws -> PendingReview {
        for _ in 0..<200 {
            if let r = try await env.client.pendingReviews().first { return r }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CancellationError()
    }

    @Test func claudeWaitsUntilTheRewriteIsApprovedOrRejected() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        _ = try await env.client.createProfile(reviewProfile())
        let launch = try await env.client.createSession(SessionSpec(name: "r", cwd: "/tmp", profile: "reviewed"))

        let approved = Task { try await env.post(launch.token, body: sampleBody(results: [("toolu_r1", "Example Domain page")])) }
        let r = try await waitForReview(env)
        #expect(r.id == "toolu_r1" && r.sessionName == "r" && r.originalText == "Example Domain page" && r.proposedText == "Morph Test Domain page")
        #expect(r.rules == ["Rename"] && r.expiresAt.timeIntervalSince(r.createdAt) == 30)
        try await env.client.resolveReview(r.id, approve: true)
        _ = try await approved.value
        #expect(try await env.client.decision("toolu_r1").replacementText == "Morph Test Domain page")

        let rejected = Task { try await env.post(launch.token, body: sampleBody(results: [("toolu_r2", "Example Domain again")])) }
        let r2 = try await waitForReview(env)
        try await env.client.resolveReview(r2.id, approve: false)
        _ = try await rejected.value
        let d = try await env.client.decision("toolu_r2")
        #expect(d.summary.outcome == .unchanged && d.summary.reason == "not rewritten: rewrite rejected in review")
        #expect(try await env.client.pendingReviews().isEmpty)
        let kinds = try await env.client.timeline(launch.session.id).events.map(\.kind)
        #expect(kinds.filter { $0 == .reviewRequested }.count == 2 && kinds.filter { $0 == .reviewResolved }.count == 2)

        // Answering twice (or after the time ran out) is a readable conflict.
        await #expect(throws: ClientError.self) { try await env.client.resolveReview("toolu_r2", approve: true) }
    }

    @Test func hookSessionsWaitForReviewToo() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        _ = try await env.client.createProfile(reviewProfile())
        let ev = HookEvent(event: "PostToolUse", claudeSessionId: "c-r", cwd: "/tmp/p", client: "claude-desktop", toolName: "WebFetch", toolUseId: "toolu_h1",
                           toolInput: #"{"url":"https://example.com","prompt":"p"}"#, toolResponse: #"{"result":"Example Domain page"}"#,
                           config: HookConfig(profile: "reviewed"))
        let reply = Task { try await env.client.hook(ev) }
        let r = try await waitForReview(env)
        #expect(r.expiresAt.timeIntervalSince(r.createdAt) <= 30)
        try await env.client.resolveReview(r.id, approve: true)
        #expect(try await reply.value.updatedToolOutput?.contains("Morph Test Domain") == true)
    }

    @Test func trialsAreNeverHeldForReview() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        _ = try await env.client.createProfile(reviewProfile())
        let trial = try await env.client.createSession(SessionSpec(name: "t", cwd: "/tmp", profile: "reviewed", kind: .trial, trialId: "tri_r"))
        _ = try await env.post(trial.token, body: sampleBody(results: [("toolu_t1", "Example Domain page")]))
        #expect(try await env.client.decision("toolu_t1").summary.outcome == .rewritten)
        #expect(try await env.client.pendingReviews().isEmpty)
    }

    @Test func unansweredReviewsTimeOut() async throws {
        let center = ReviewCenter()
        let review = PendingReview(id: "x", sessionId: "s", sessionName: "s", toolName: "WebFetch", toolInput: nil, stage: .result, originalText: "a",
                                   proposedText: "b", explanation: "e", rules: [], createdAt: Date(), expiresAt: Date().addingTimeInterval(0.1))
        #expect(await center.wait(for: review) {} == .timedOut)
        #expect(await center.pending.isEmpty)
        #expect(await center.resolve("x", .approved) == false)
        #expect(DecisionEngine.clampedReviewTimeout(1) == 15 && DecisionEngine.clampedReviewTimeout(999) == 120)
    }
}
