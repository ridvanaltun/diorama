import DioramaClient
import DioramaCore
import DioramaTestSupport
import Foundation
import Testing

@Suite struct ImpactAPITests {
    func run(reply: String) async throws -> (TestEnv, String) {
        let mock = MockUpstream { _ in .sse(MockUpstream.sseEvents(text: reply)) }
        try await mock.start()
        let env = try await TestEnv.start(mock: mock)
        _ = try await env.client.createProfile(Profile(name: "web", rules: [Rule(name: "Rename", match: RuleMatch(tools: ["WebFetch"]), instructions: "rename")]))
        let s = try await env.client.createSession(SessionSpec(name: "s", cwd: "/tmp", profile: "web"))
        _ = try await env.post(s.token, body: sampleBody(results: [("toolu_im1", "Example Domain page")]))
        return (env, s.session.id)
    }

    @Test func showsWhetherClaudeUsedTheRewrite() async throws {
        let (env, id) = try await run(reply: "The page heading is Morph Test Domain.")
        defer { Task { await env.stop() } }
        let impact = try #require(try await env.client.impact(id).first)
        #expect(impact.toolUseId == "toolu_im1" && impact.signals == [.used] && impact.label == "used")
        #expect(impact.evidence.first?.contains("Morph Test") == true)
        let report = try await env.client.sessionReport(id)
        #expect(report.contains("Did Claude use it (heuristic): **used**") && report.contains("Rewrites Claude used (heuristic): 1 of 1"))
    }

    @Test func noSignWhenTheReplyDoesntMentionIt() async throws {
        let (env, id) = try await run(reply: "Done.")
        defer { Task { await env.stop() } }
        #expect(try await env.client.impact(id).map(\.status) == [.noSign])
    }
}
