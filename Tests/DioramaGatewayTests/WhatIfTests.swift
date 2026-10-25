import DioramaClient
import DioramaCore
import Foundation
import Testing
@testable import DioramaGateway

/// Changes by tool_use_id (results decided in the same request have no meaningful order).
func changes(_ r: WhatIfResult) -> [String: WhatIfChange] { Dictionary(uniqueKeysWithValues: r.items.map { ($0.toolUseId, $0.change) }) }
func item(_ r: WhatIfResult, _ id: String) -> WhatIfItem? { r.items.first { $0.toolUseId == id } }

@Suite struct WhatIfTests {
    let results = [(id: "toolu_a", text: "Example Domain page"), (id: "toolu_b", text: "Nothing to see")]

    @Test func comparesVersionsAndRecordsNothing() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        let v1 = try await env.client.createProfile(Profile(name: "web steer", rules: [Rule(name: "Rename", match: RuleMatch(tools: ["WebFetch"]), instructions: "rename")]))
        let launch = try await env.client.createSession(SessionSpec(name: "w", cwd: "/tmp", profile: "web steer"))
        _ = try await env.post(launch.token, body: sampleBody(results: results))
        let before = try await env.client.timeline(launch.session.id).decisions
        #expect(Set(before.map(\.outcome)) == [.rewritten, .unchanged])

        // v2 only targets Read: the WebFetch rewrite would disappear. Checking is free.
        _ = try await env.client.updateProfile("web steer", Profile(name: "web steer", rules: [Rule(name: "Read only", match: RuleMatch(tools: ["Read"]), instructions: "x")]))
        let current = try await env.client.whatIf(WhatIfRequest(sessionId: launch.session.id, profileRef: "web steer"))
        #expect(current.rulesLabel == "“web steer” v2")
        #expect(changes(current) == ["toolu_a": .noLongerRewritten, "toolu_b": .sameUnchanged])
        #expect(current.calls == 0)

        // Back to v1: both match; the check estimates two calls, the run reproduces the same rewrite.
        let check = try await env.client.whatIf(WhatIfRequest(sessionId: launch.session.id, profileVersionId: v1.id))
        #expect(changes(check) == ["toolu_a": .wouldRewrite, "toolu_b": .wouldRewrite])
        #expect(check.calls == 2)
        #expect(check.estimateHighUSD >= check.estimateLowUSD && check.estimateLowUSD > 0)
        let run = try await env.client.whatIf(WhatIfRequest(sessionId: launch.session.id, profileVersionId: v1.id, rewrite: true))
        #expect(changes(run) == ["toolu_a": .sameRewrite, "toolu_b": .sameUnchanged])
        #expect(item(run, "toolu_a")?.beforeText == "Morph Test Domain page")

        // A limit leaves the rest unrun.
        let capped = try await env.client.whatIf(WhatIfRequest(sessionId: launch.session.id, profileVersionId: v1.id, rewrite: true, maxRewrites: 1))
        #expect(capped.count(.skipped) == 1 && capped.calls == 1)

        #expect(try await env.client.timeline(launch.session.id).decisions == before, "what-if must not change the record")
        await #expect(throws: ClientError.self) { _ = try await env.client.whatIf(WhatIfRequest(sessionId: launch.session.id)) }
        await #expect(throws: ClientError.self) { _ = try await env.client.whatIf(WhatIfRequest(sessionId: "ses_missing", profileRef: "web steer")) }
    }

    @Test func showsResultsTheNewRulesWouldRewrite() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        let launch = try await env.client.createSession(SessionSpec(name: "record only", cwd: "/tmp"))
        _ = try await env.post(launch.token, body: sampleBody(results: results))
        let draft = Profile(name: "draft", rules: [Rule(name: "Rename", match: RuleMatch(tools: ["WebFetch"]), instructions: "rename")])
        let r = try await env.client.whatIf(WhatIfRequest(sessionId: launch.session.id, profile: draft, rewrite: true))
        #expect(r.rulesLabel == "“draft” (draft)")
        #expect(changes(r) == ["toolu_a": .nowRewritten, "toolu_b": .sameUnchanged])
        #expect(item(r, "toolu_a")?.afterText == "Morph Test Domain page")
        #expect(item(r, "toolu_a")?.matchedRules == ["Rename"])

        // The MCP tool refuses paid runs on a read-only server but checks for free.
        let ro = MCPServer(cliPath: "/x/diorama", readOnly: true) { env.client }
        let line = String(decoding: try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": [
            "name": "what_if_replay", "arguments": ["session_id": launch.session.id, "profile_draft": ["name": "d", "rules": [["name": "R", "match": ["tools": ["WebFetch"]], "instructions": "x"]]], "rewrite": true],
        ]]), as: UTF8.self)
        let raw = try #require(await ro.handle(line))
        #expect(raw.contains("read-only") && raw.contains("\"isError\":true"))
    }
}
