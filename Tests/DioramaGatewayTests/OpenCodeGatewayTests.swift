import DioramaClient
import DioramaCore
import DioramaTestSupport
import Foundation
import Testing
@testable import DioramaGateway

/// A request shaped like OpenCode 2's (Anthropic provider): lowercase tool names, string
/// `tool_result` content with `cache_control`, and a system prompt array.
func openCodeBody(results: [(id: String, text: String)]) -> [UInt8] {
    var msgs = [#"{"role":"user","content":[{"type":"text","text":"Fetch example.com"}]}"#]
    for r in results {
        msgs.append(#"{"role":"assistant","content":[{"type":"tool_use","id":"\#(r.id)","name":"webfetch","input":{"url":"https://example.com","format":"markdown"}}]}"#)
        msgs.append(#"{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(r.id)","content":"\#(r.text)","cache_control":{"type":"ephemeral"}}]}"#)
    }
    return Array(#"{"model":"claude-sonnet-4-5","max_tokens":64000,"system":[{"type":"text","text":"You are OpenCode"}],"tools":[{"name":"webfetch","description":"d","input_schema":{"type":"object"}}],"messages":[\#(msgs.joined(separator: ","))],"stream":true}"#.utf8)
}

@Suite(.serialized) struct OpenCodeGatewayTests {
    func post(_ env: TestEnv, _ token: String, _ body: [UInt8]) async throws -> Int {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(env.port)/s/\(token)/v1/messages?beta=true")!)
        req.httpMethod = "POST"
        req.httpBody = Data(body)
        let headers = ["content-type": "application/json", "anthropic-version": "2023-06-01", "x-api-key": "sk-ant-user-key",
                       "user-agent": "opencode/latest/2.1.4/desktop", "x-opencode-session-id": "ses_opencode1"]
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (_, resp) = try await URLSession.shared.data(for: req)
        return (resp as! HTTPURLResponse).statusCode
    }

    @Test func launchRoutesOpenCodesAnthropicProviderWithoutClaudeSettings() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        let launch = try await env.client.createSession(SessionSpec(name: "oc", cwd: "/tmp", lockdown: .network, agent: .opencode))
        #expect(launch.claudeArguments == ["--standalone"])
        #expect(launch.environment["ANTHROPIC_BASE_URL"] == nil)
        #expect(launch.environment["DIORAMA_SESSION"] == launch.session.id)
        let json = try #require(launch.environment[OpenCodeLaunch.configVariable])
        let config = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let anthropic = (config["providers"] as? [String: Any])?["anthropic"] as? [String: Any]
        #expect((anthropic?["settings"] as? [String: Any])?["baseURL"] as? String == launch.baseURL + "/v1")
        let permissions = try #require(config["permissions"] as? [[String: String]])
        #expect(permissions.contains(["action": "shell", "resource": "wget *", "effect": "deny"]))
    }

    @Test func rewritesOpenCodeToolResultsWithClaudeCodeRules() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        // A profile written for Claude Code (`WebFetch`) steers OpenCode's `webfetch`.
        _ = try await env.client.createProfile(Profile(name: "web", rules: [Rule(name: "r", match: RuleMatch(tools: ["WebFetch"]), instructions: "rename")]))
        let launch = try await env.client.createSession(SessionSpec(name: "oc", cwd: "/tmp", profile: "web", agent: .opencode))
        let body = openCodeBody(results: [("toolu_oc1", "Example Domain page")])
        #expect(try await post(env, launch.token, body) == 200)
        let first = try #require(env.mock.requests.last)
        #expect(first.uri == "/v1/messages?beta=true")
        #expect(first.header("x-api-key") == "sk-ant-user-key")
        #expect(String(decoding: first.body, as: UTF8.self) == String(decoding: body, as: UTF8.self).replacingOccurrences(of: "Example Domain page", with: "Morph Test Domain page"))

        // Next turn: the rewrite is replayed byte for byte.
        _ = try await post(env, launch.token, openCodeBody(results: [("toolu_oc1", "Example Domain page"), ("toolu_oc2", "Example Domain again")]))
        let second = String(decoding: try #require(env.mock.requests.last).body, as: UTF8.self)
        #expect(second.contains(#""content":"Morph Test Domain page","cache_control""#))
        #expect(second.contains("Morph Test Domain again"))

        let detail = try await env.client.decision("toolu_oc1")
        #expect(detail.summary.outcome == .rewritten)
        #expect(detail.summary.toolName == "webfetch")
        let tl = try await env.client.timeline(launch.session.id)
        #expect(tl.session.claudeSessionIds == ["ses_opencode1"])
        #expect(tl.exchanges.last?.toolResults.map(\.handling) == [.replayedRewritten, .decidedRewritten])
        let raw = try await env.client.exchangeRaw(try #require(tl.exchanges.first).id)
        #expect(raw.requestHeaders?.contains("sk-ant-user-key") == false)
    }

    @Test func warnsAboutRulesOpenCodeCantApply() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        let launch = try await env.client.createSession(SessionSpec(
            name: "oc", cwd: "/tmp", prompt: SessionPrompt(text: "edit the page", stage: .page), agent: .opencode))
        let tl = try await env.client.timeline(launch.session.id)
        #expect(tl.events.contains { $0.kind == .warning && $0.message.contains("Page rules don't apply to OpenCode") })
    }
}
