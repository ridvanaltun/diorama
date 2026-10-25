import DioramaClient
import DioramaCore
import Foundation
import Testing
@testable import DioramaGateway

@Suite struct SessionReportTests {
    @Test func reportsChangesUnchangedResultsAndEscapesHTML() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        _ = try await env.client.createProfile(Profile(name: "web", rules: [Rule(name: "Rename", match: RuleMatch(tools: ["WebFetch"]), instructions: "rename")]))
        let launch = try await env.client.createSession(SessionSpec(name: "report <demo>", cwd: "/tmp", profile: "web"))
        _ = try await env.post(launch.token, body: sampleBody(results: [("toolu_r1", "Example Domain page <script>alert(1)</script>"), ("toolu_r2", "Nothing here")]))

        let md = try await env.client.sessionReport(launch.session.id, format: "md")
        #expect(md.hasPrefix("# Diorama session report: report <demo>"))
        #expect(md.contains("## What Diorama changed") && md.contains("### 1. WebFetch result — https://example.com"))
        #expect(md.contains("~~Example~~") && md.contains("**Morph Test**"))
        #expect(md.contains("- Rules: Rename"))
        #expect(md.contains("## Left unchanged") && md.contains("'Example Domain' not present"))
        #expect(md.contains("profile “web” v1"))

        let html = try await env.client.sessionReport(launch.session.id, format: "html")
        #expect(html.hasPrefix("<!doctype html>"))
        #expect(html.contains("<del>Example</del>") && html.contains("<ins>Morph Test</ins>"))
        #expect(!html.contains("<script>alert(1)</script>"), "tool results are escaped, never injected")
        #expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        #expect(html.contains("<title>Diorama session report: report &lt;demo&gt;</title>"))

        await #expect(throws: ClientError.self) { _ = try await env.client.sessionReport(launch.session.id, format: "pdf") }
        await #expect(throws: ClientError.self) { _ = try await env.client.sessionReport("ses_missing") }
    }

    @Test func hookSessionsReportReadableText() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        _ = try await env.client.createProfile(Profile(name: "web", rules: [Rule(name: "Rename", match: RuleMatch(tools: ["WebFetch"]), instructions: "rename")]))
        let reply = try await env.client.hook(HookEvent(event: "PostToolUse", claudeSessionId: "c-rep", cwd: "/tmp/app", client: "claude-desktop", toolName: "WebFetch",
                                                        toolUseId: "toolu_h1", toolInput: #"{"url":"https://example.com"}"#,
                                                        toolResponse: #"{"code":200,"result":"Example Domain page"}"#, config: HookConfig(profile: "web")))
        let md = try await env.client.sessionReport(try #require(reply.sessionId))
        #expect(md.contains("hook mode"))
        #expect(md.contains("~~Example~~ Domain page") || md.contains("~~Example~~"))
        #expect(!md.contains(#""code":200"#), "the report shows the text Claude read, not the raw tool JSON")
    }
}
