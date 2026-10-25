import DioramaClient
import DioramaCore
import DioramaTestSupport
import Foundation
import Testing
@testable import DioramaGateway

@Suite struct PlaygroundEndpointTests {
    @Test func testsSavedProfilesDraftsAndPastResults() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        _ = try await env.client.createProfile(Profile(name: "Docs steer", rules: [Rule(name: "Rename", match: RuleMatch(tools: ["WebFetch"]), instructions: "rename")]))

        // Pasted text against a saved profile (looked up by a name with a space).
        let pasted = try await env.client.playground(PlaygroundRequest(profileRef: "Docs steer", text: "Heading: Example Domain", toolName: "WebFetch", rewrite: true))
        #expect(pasted.checks.map(\.matches) == [true])
        #expect(pasted.rewrite?.replacementText == "Heading: Morph Test Domain")

        // A past gateway result (its original), against an unsaved draft that doesn't match it.
        let launch = try await env.client.createSession(SessionSpec(name: "p", cwd: "/tmp", profile: "Docs steer"))
        _ = try await env.post(launch.token, body: sampleBody())
        let recent = try await env.client.recentToolResults()
        let past = try #require(recent.first)
        #expect(past.sessionName == "p")
        #expect(past.decision.outcome == .rewritten)
        let draft = Profile(name: "draft", rules: [Rule(name: "Only Read", match: RuleMatch(tools: ["Read"]), instructions: "x")])
        let r = try await env.client.playground(PlaygroundRequest(profile: draft, toolUseId: past.decision.toolUseId))
        #expect(r.originalText.contains("Example Domain"), "the playground starts from the original, not the rewrite")
        #expect(r.checks.first?.reason == "WebFetch isn't in the rule's tools (Read)")
        #expect(try await env.client.recentToolResults().count == recent.count, "testing records nothing")

        // A past hook-mode result is tested on its text, not its JSON.
        _ = try await env.client.hook(HookEvent(event: "PostToolUse", claudeSessionId: "c1", cwd: "/tmp/x", toolName: "WebFetch", toolUseId: "toolu_hk",
                                                toolInput: #"{"url":"https://example.com"}"#, toolResponse: #"{"code":200,"result":"Example Domain page"}"#))
        let hook = try await env.client.playground(PlaygroundRequest(profileRef: "Docs steer", toolUseId: "toolu_hk"))
        #expect(hook.originalText == "Example Domain page")

        await #expect(throws: ClientError.self) { _ = try await env.client.playground(PlaygroundRequest(profileRef: "missing", text: "x")) }
        await #expect(throws: ClientError.self) { _ = try await env.client.playground(PlaygroundRequest(profileRef: "Docs steer")) }
    }

    @Test func mcpToolRespectsReadOnly() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        _ = try await env.client.createProfile(Profile(name: "web", rules: [Rule(name: "Rename", match: RuleMatch(tools: ["WebFetch"]), instructions: "rename")]))
        func call(_ server: MCPServer, _ args: [String: Any]) async throws -> (String, Bool) {
            let line = String(decoding: try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "test_rules", "arguments": args]]), as: UTF8.self)
            let raw = try #require(await server.handle(line))
            let reply = try #require(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
            let result = try #require(reply["result"] as? [String: Any])
            return (((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "", result["isError"] as? Bool ?? false)
        }
        let full = MCPServer(cliPath: "/x/diorama") { env.client }
        let (text, isError) = try await call(full, ["profile": "web", "text": "Example Domain", "tool_input": ["url": "https://example.com"], "rewrite": true])
        #expect(!isError, "\(text)")
        #expect(text.contains("MATCH Rename") && text.contains("Morph Test Domain"))

        let ro = MCPServer(cliPath: "/x/diorama", readOnly: true) { env.client }
        let (refused, refusedIsError) = try await call(ro, ["profile": "web", "text": "Example Domain", "rewrite": true])
        #expect(refusedIsError && refused.contains("read-only"))
        let (checked, checkedIsError) = try await call(ro, ["profile": "web", "text": "Example Domain"])
        #expect(!checkedIsError && checked.contains("MATCH Rename"))
    }
}
