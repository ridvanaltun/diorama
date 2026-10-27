import DioramaClient
import DioramaCore
import Foundation
import Testing

@Suite struct AnnotationTests {
    @Test func renamesNotesAndTagsSessions() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        let a = try await env.client.createSession(SessionSpec(name: "a", cwd: "/tmp"))
        let b = try await env.client.createSession(SessionSpec(name: "b", cwd: "/tmp"))

        var info = try await env.client.annotate(a.session.id, SessionAnnotations(name: "  Baseline run ", notes: "Steering off.\nDocs v2.", tags: [" baseline", "Docs-v2", "BASELINE", ""]))
        #expect(info.name == "Baseline run" && info.notes == "Steering off.\nDocs v2." && info.tags == ["baseline", "Docs-v2"])
        // Nil fields are left alone.
        info = try await env.client.annotate(a.session.id, SessionAnnotations(tags: ["baseline", "keep"]))
        #expect(info.name == "Baseline run" && info.notes == "Steering off.\nDocs v2." && info.tags == ["baseline", "keep"])
        _ = try await env.client.annotate(b.session.id, SessionAnnotations(tags: ["Baseline"]))

        #expect(try await env.client.sessions(tag: "baseline").map(\.id).sorted() == [a.session.id, b.session.id].sorted())
        #expect(try await env.client.sessions(tag: "keep").map(\.id) == [a.session.id])
        #expect(try await env.client.sessions(tag: "nope").isEmpty)
        let tags = try await env.client.sessionTags()
        #expect(tags.first?.lowercased() == "baseline" && tags == [tags[0], "keep"] && tags.count == 2, "case-insensitive: \(tags)")

        await #expect(throws: ClientError.self) { try await env.client.annotate(a.session.id, SessionAnnotations(name: "   ")) }
        await #expect(throws: ClientError.self) {
            try await env.client.annotate(a.session.id, SessionAnnotations(notes: String(repeating: "x", count: SessionAnnotations.maxNotesLength + 1)))
        }
        await #expect(throws: ClientError.self) { try await env.client.annotate("ses_missing", SessionAnnotations(notes: "x")) }

        let report = try await env.client.sessionReport(a.session.id)
        #expect(report.contains("- Tags: baseline, keep") && report.contains("## Notes\n\nSteering off.\nDocs v2."))
        let html = try await env.client.sessionReport(a.session.id, format: "html")
        #expect(html.contains("<h2>Notes</h2>"))

        let server = MCPServer(cliPath: "/x/diorama", hookRegistry: HookRegistry(paths: DioramaPaths(home: env.home))) { env.client }
        let msg: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                  "params": ["name": "annotate_session", "arguments": ["session_id": b.session.id, "tags": ["mcp"]]]]
        let reply = await server.handle(String(decoding: try JSONSerialization.data(withJSONObject: msg), as: UTF8.self))
        #expect(reply?.contains("tags: mcp") == true)
        #expect(try await env.client.session(b.session.id).tags == ["mcp"])
    }

    @Test func normalizesTags() {
        let many = (0..<30).map { "t\($0)" }
        #expect(SessionAnnotations.normalizedTags(many).count == SessionAnnotations.maxTags)
        #expect(SessionAnnotations.normalizedTags([String(repeating: "a", count: 60)]) == [String(repeating: "a", count: 40)])
    }
}
