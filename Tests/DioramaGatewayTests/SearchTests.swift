import DioramaClient
import DioramaCore
import DioramaStore
import Foundation
import Testing
@testable import DioramaGateway

@Suite struct SearchTests {
    @Test func userInputCantBreakTheQuerySyntax() {
        // All words must match; the last (2+ letters) is also a prefix, for search as you type.
        #expect(Store.searchExpression("deprecated api") == #""deprecated" "api"*"#)
        #expect(Store.searchExpression("a") == #""a""#)
        #expect(Store.searchExpression(#"say "hi""#) == #""say" """hi""""# + "*")
        #expect(Store.searchExpression("   ") == nil)
    }

    /// Indexing runs on the daemon's event stream; give it a moment.
    func search(_ env: TestEnv, _ q: String, rewrittenOnly: Bool = false, session: String? = nil) async throws -> [SearchHit] {
        for _ in 0..<40 {
            let hits = try await env.client.search(q, rewrittenOnly: rewrittenOnly, sessionId: session)
            if !hits.isEmpty { return hits }
            try await Task.sleep(for: .milliseconds(50))
        }
        return []
    }

    @Test func findsOriginalsRewritesAndReplies() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        _ = try await env.client.createProfile(Profile(name: "web", rules: [Rule(name: "Rename", match: RuleMatch(tools: ["WebFetch"]), instructions: "rename")]))
        let launch = try await env.client.createSession(SessionSpec(name: "searchable", cwd: "/tmp", profile: "web"))
        _ = try await env.post(launch.token, body: sampleBody(results: [("toolu_s1", "Example Domain page"), ("toolu_s2", "Quarterly zebra report")]))

        let rewritten = try await search(env, "Morph Test")
        #expect(rewritten.first?.ref == "toolu_s1" && rewritten.first?.outcome == .rewritten && rewritten.first?.sessionName == "searchable")
        #expect(rewritten.first?.snippet.contains("⟦Morph⟧") == true)
        let original = try await search(env, "zebra")
        #expect(original.map(\.ref) == ["toolu_s2"])
        #expect(try await env.client.search("zebra", rewrittenOnly: true).isEmpty)
        #expect(try await search(env, "quart").first?.ref == "toolu_s2", "the last word matches as a prefix")
        #expect(try await search(env, "example.com").contains { $0.ref == "toolu_s1" }, "tool inputs (URLs) are searchable")
        #expect(try await env.client.search("zebra", sessionId: "ses_other").isEmpty)
        // The mock model replies "Hello".
        #expect(try await search(env, "hello").contains { $0.kind == .reply && $0.sessionId == launch.session.id })
        #expect(try await env.client.search(#"NEAR( "unbalanced -x *"#).isEmpty, "odd input is searched literally, not rejected")
    }

    @Test func backfillIndexesOlderRecords() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        let store = env.daemon.store
        let launch = try await env.client.createSession(SessionSpec(name: "old", cwd: "/tmp"))
        // A decision written without an event, as if recorded before search existed.
        let blob = try store.blobs.put(Array(#""An old armadillo result""#.utf8))
        _ = try store.insertDecision(DecisionRecord(
            toolUseId: "toolu_old", sessionId: launch.session.id, exchangeId: 0, toolName: "Read", toolInput: nil, isError: false,
            originalHash: "h", originalBlob: blob, outcome: .unchanged, reason: "no rule matched", replacementBlob: nil, rules: [], instructions: []))
        // (The daemon's own startup backfill may get to it first under load; either way it's the same code.)
        DioramaDaemon.backfillSearch(store: store)
        #expect(try await env.client.search("armadillo").map(\.ref) == ["toolu_old"])
        DioramaDaemon.backfillSearch(store: store)
        #expect(try await env.client.search("armadillo").count == 1, "indexed once")
    }
}
