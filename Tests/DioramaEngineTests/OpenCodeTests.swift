import DioramaCore
import DioramaJSON
import Foundation
import Testing
@testable import DioramaEngine

@Suite struct OpenCodeTests {
    func ctx(_ tool: String) -> MatchContext {
        MatchContext(toolName: tool, toolInput: .object([:]), text: "page", requestClass: nil, isError: false)
    }

    @Test func rulesMatchTheOtherAgentsToolNames() {
        let claudeRule = Rule(name: "r", match: RuleMatch(tools: ["WebFetch", "Bash"]), instructions: "x")
        #expect(RuleMatcher.matches(claudeRule, ctx("webfetch")))
        #expect(RuleMatcher.matches(claudeRule, ctx("shell")))
        #expect(RuleMatcher.matches(claudeRule, ctx("bash")))
        #expect(!RuleMatcher.matches(claudeRule, ctx("websearch")))
        let openCodeRule = Rule(name: "r", match: RuleMatch(tools: ["read"]), instructions: "x")
        #expect(RuleMatcher.matches(openCodeRule, ctx("Read")))
        #expect(!RuleMatcher.matches(openCodeRule, ctx("Write")))
        let globRule = Rule(name: "r", match: RuleMatch(tools: ["Web*"]), instructions: "x")
        #expect(RuleMatcher.matches(globRule, ctx("websearch")))
        #expect(RuleMatcher.mismatch(claudeRule, ctx("grep")) == "grep isn't in the rule's tools (WebFetch, Bash)")
    }

    @Test func shellToolNames() {
        #expect(ToolNames.isShell("Bash") && ToolNames.isShell("shell") && ToolNames.isShell("bash"))
        #expect(!ToolNames.isShell("read"))
        #expect(ToolNames.equivalents("mcp__docs__search").isEmpty)
    }

    @Test func standaloneGoesWhereOpenCodeAcceptsIt() throws {
        let launch = ["--standalone"]
        #expect(try OpenCodeLaunch.arguments(user: [], launch: launch).get() == ["--standalone"])
        #expect(try OpenCodeLaunch.arguments(user: ["--auto", "~/code/app"], launch: launch).get() == ["--standalone", "--auto", "~/code/app"])
        #expect(try OpenCodeLaunch.arguments(user: ["run", "-m", "anthropic/claude-sonnet-4-5", "hi"], launch: launch).get()
            == ["run", "--standalone", "-m", "anthropic/claude-sonnet-4-5", "hi"])
        #expect(try OpenCodeLaunch.arguments(user: ["mini", "--standalone"], launch: launch).get() == ["mini", "--standalone"])
        #expect(throws: OpenCodeLaunch.ArgumentProblem.self) { try OpenCodeLaunch.arguments(user: ["serve"], launch: launch).get() }
        #expect(throws: OpenCodeLaunch.ArgumentProblem.self) { try OpenCodeLaunch.arguments(user: ["--server", "http://x"], launch: launch).get() }
        #expect(throws: OpenCodeLaunch.ArgumentProblem.self) { try OpenCodeLaunch.arguments(user: ["run", "--server=http://x"], launch: launch).get() }
    }

    @Test func trialToolListsBecomeOpenCodePermissions() {
        let rules = OpenCodeTrial.permissions(allowed: ["WebFetch", "read", "Bash(git log:*)", "mcp__docs__search", " "], disallowed: ["Write"])
        #expect(rules == [
            ["action": "*", "resource": "*", "effect": "deny"],
            ["action": "webfetch", "resource": "*", "effect": "allow"],
            ["action": "read", "resource": "*", "effect": "allow"],
            ["action": "shell", "resource": "git log *", "effect": "allow"],
            ["action": "docs_search", "resource": "*", "effect": "allow"],
            ["action": "write", "resource": "*", "effect": "deny"],
        ])
        #expect(OpenCodeTrial.permissions(allowed: [], disallowed: []).isEmpty, "no list: OpenCode's own defaults")
    }

    @Test func trialConfigurationPutsLockdownLastAndLimitsSteps() throws {
        let session = OpenCodeLaunch.configuration(gatewayBase: "http://h/s/t", lockdown: .network)
        let config = OpenCodeTrial.configuration(ClaudeRunOptions(allowedTools: ["Bash"], maxTurns: 7), session: session)
        let rules = try #require(config["permissions"] as? [[String: String]])
        #expect(rules.first == ["action": "*", "resource": "*", "effect": "deny"])
        #expect(rules[1] == ["action": "shell", "resource": "*", "effect": "allow"])
        #expect(rules.last?["effect"] == "deny" && rules.count == 2 + LockdownPreset.network.blockedPrograms.count, "lockdown's denials come after the allow")
        #expect(((config["agents"] as? [String: Any])?["build"] as? [String: Any])?["steps"] as? Int == 7)
        #expect(config["providers"] != nil)
        #expect(OpenCodeTrial.arguments(ClaudeRunOptions(model: "claude-sonnet-4-5", extraArguments: ["--agent", "build"]))
            == ["run", "--standalone", "--auto", "--format", "json", "-m", "anthropic/claude-sonnet-4-5", "--agent", "build"])
    }

    @Test func openCodeExperimentsNeedAnAnthropicModel() throws {
        let dir = FileManager.default.temporaryDirectory.path
        func problems(_ model: String?, agent: CodingAgent? = .opencode) -> [String] {
            ExperimentDefinition(name: "x", task: "t", projectPath: dir, claude: ClaudeRunOptions(model: model),
                                 variants: [ExperimentVariant(key: "control", name: "c"), ExperimentVariant(key: "s", name: "s", profile: "p")], agent: agent).validate()
        }
        #expect(problems(nil).contains { $0.contains("need a model") })
        #expect(problems("openai/gpt-6").contains { $0.contains("only use Anthropic models") })
        #expect(problems("claude-sonnet-4-5").isEmpty && problems("anthropic/claude-sonnet-4-5").isEmpty)
        #expect(problems(nil, agent: nil).isEmpty, "Claude Code experiments may use its default model")
        #expect(OpenCodeTrial.modelId("anthropic/claude-sonnet-4-5") == "claude-sonnet-4-5")

        // Claude Code definitions encode as before, so their hashes don't change.
        let plain = ExperimentDefinition(name: "x", task: "t", projectPath: dir, variants: [])
        #expect(!String(decoding: try DioramaCoding.encoder.encode(plain), as: UTF8.self).contains("agent"))
        let decoded = try DioramaCoding.decoder.decode(ExperimentDefinition.self, from: Data(#"{"name":"x","task":"t","projectPath":"/","variants":[],"agent":"opencode"}"#.utf8))
        #expect(decoded.runsOpenCode)
    }

    @Test func parsesOpenCodeRunOutput() {
        let ok = """
        {"type":"step_start","sessionID":"ses_1","part":{"messageID":"msg_a","type":"step-start"}}
        {"type":"step_start","sessionID":"ses_1","part":{"messageID":"msg_a","type":"step-start"}}
        {"type":"tool_use","sessionID":"ses_1","part":{"messageID":"msg_a","tool":"read","state":{"status":"completed","input":{"path":"a.txt"}}}}
        {"type":"step_finish","sessionID":"ses_1","part":{"messageID":"msg_a","reason":"tool-calls"}}
        not json
        {"type":"step_start","sessionID":"ses_1","part":{"messageID":"msg_b","type":"step-start"}}
        {"type":"tool_use","sessionID":"ses_1","part":{"messageID":"msg_b","tool":"shell","state":{"status":"error","input":{"command":"ls"}}}}
        {"type":"text","sessionID":"ses_1","part":{"messageID":"msg_c","text":"Part one."}}
        {"type":"text","sessionID":"ses_1","part":{"messageID":"msg_c","text":"Part two."}}
        """
        let o = OpenCodeOutput.parse(ok)
        #expect(o.sessionId == "ses_1")
        #expect(o.numTurns == 3, "a retried message counts once, and a message without step_start still counts")
        #expect(o.toolSequence == [OpenCodeOutput.ToolCall(name: "read", input: #"{"path":"a.txt"}"#), OpenCodeOutput.ToolCall(name: "shell", input: #"{"command":"ls"}"#)])
        #expect(o.finalOutput == "Part one.\nPart two.")
        #expect(o.error == nil)

        let failed = OpenCodeOutput.parse(#"{"type":"step_start","part":{"messageID":"m"}}"# + "\n" + #"{"type":"error","error":{"type":"provider.auth","message":"invalid x-api-key"}}"#)
        #expect(failed.error == "invalid x-api-key" && failed.finalOutput.isEmpty)
    }

    @Test func configurationRoutesAnthropicAndMergesOverTheUsersInlineConfig() throws {
        let config = OpenCodeLaunch.configuration(gatewayBase: "http://127.0.0.1:47821/s/abc", lockdown: .network)
        let existing = #"{"model":"anthropic/claude-sonnet-4-5","providers":{"anthropic":{"settings":{"baseURL":"https://proxy.example","headerTimeout":1000}},"openai":{}},"permissions":[{"action":"shell","resource":"curl *","effect":"allow"}]}"#
        let (value, replaced) = OpenCodeLaunch.environmentValue(existing: existing, overlay: config)
        #expect(!replaced)
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
        #expect(obj["model"] as? String == "anthropic/claude-sonnet-4-5")
        let providers = try #require(obj["providers"] as? [String: Any])
        #expect(providers["openai"] != nil)
        let settings = try #require((providers["anthropic"] as? [String: Any])?["settings"] as? [String: Any])
        #expect(settings["baseURL"] as? String == "http://127.0.0.1:47821/s/abc/v1")
        #expect(settings["headerTimeout"] as? Int == 1000)
        // The user's allow comes first, so Diorama's deny (last match wins) takes effect.
        let permissions = try #require(obj["permissions"] as? [[String: String]])
        #expect(permissions.first?["effect"] == "allow")
        #expect(permissions.dropFirst().contains(["action": "shell", "resource": "curl *", "effect": "deny"]))
        #expect(permissions.count == 1 + LockdownPreset.network.blockedPrograms.count)

        let (fresh, _) = OpenCodeLaunch.environmentValue(existing: nil, overlay: OpenCodeLaunch.configuration(gatewayBase: "http://h/s/t", lockdown: .none))
        #expect(fresh == #"{"providers":{"anthropic":{"settings":{"baseURL":"http://h/s/t/v1"}}}}"#)
        #expect(OpenCodeLaunch.environmentValue(existing: "not json", overlay: [:]).replacedInvalid)
    }
}
