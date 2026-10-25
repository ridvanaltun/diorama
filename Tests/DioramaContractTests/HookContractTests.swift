import DioramaClient
import DioramaCore
import DioramaRunner
import DioramaTestSupport
import Foundation
import Testing
@testable import DioramaGateway

/// The `diorama` CLI built next to these tests (`swift build` builds it; CI builds before testing).
let dioramaCLI: String? = {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let path = root.appendingPathComponent(".build/debug/diorama").path
    return FileManager.default.isExecutableFile(atPath: path) ? path : nil
}()

/// Hook mode against the real Claude Code: the hook installed in the project's
/// .claude/settings.local.json runs the real `diorama hook run`, which talks to the daemon.
@Suite(.serialized, .enabled(if: claudePath != nil && dioramaCLI != nil, "requires the claude CLI and a built diorama CLI"))
struct HookContractTests {
    func install(_ h: ClaudeHarness, project: URL, profile: String) throws {
        let command = try HookInstaller.command(cli: dioramaCLI!, config: HookConfig(profile: profile))
        try HookInstaller.install(command: command, settings: HookInstaller.projectSettings(project.path))
    }

    /// Claude Code talking straight to the (mock) model, like a Claude desktop session: only the hook involves Diorama.
    func runDirect(_ h: ClaudeHarness, prompt: String, cwd: URL, args: [String]) throws -> ProcessRunner.Result {
        var env = ClaudeHarness.claudeEnvironment(home: h.fakeUserHome)
        env["ANTHROPIC_BASE_URL"] = h.mock.url.absoluteString
        env["DIORAMA_HOME"] = h.home.appendingPathComponent("diorama").path
        env["CLAUDE_CODE_ENTRYPOINT"] = "claude-desktop"
        return try ProcessRunner.run(claudePath!, ["-p", prompt, "--output-format", "json"] + args, cwd: cwd.path, environment: env, timeout: 120)
    }

    @Test func hookRewritesToolResultsInASessionDioramaDoesNotRoute() async throws {
        let h = try await ClaudeHarness.start(steps: [])
        defer { Task { await h.stop() } }
        let project = try h.makeProject(files: ["notes.txt": "Example Domain\nsecond line"])
        let model = ScriptedModel(steps: [.init("Read", ["file_path": project.appendingPathComponent("notes.txt").path])])
        h.mock.setHandler { model.respond($0) }
        _ = try await h.client.createProfile(Profile(name: "read", rules: [Rule(name: "r", match: RuleMatch(tools: ["Read"]), instructions: "rename the domain")]))
        try install(h, project: project, profile: "read")

        let r = try runDirect(h, prompt: "Read notes.txt", cwd: project, args: ["--allowedTools", "Read"])
        #expect(r.exitCode == 0, "stderr: \(r.stderr)")
        let text = resultText(r.stdout)
        #expect(text.contains("Morph Test Domain"), "stdout: \(r.stdout)")
        #expect(!text.contains("Example Domain"))
        #expect(h.rewriteCalls == 1)

        let session = try #require(try await h.client.sessions().first { $0.via == .hook })
        #expect(session.name.hasSuffix("· Desktop"))
        #expect(session.stats.rewrites == 1)
        #expect(session.status == .ended, "SessionEnd should end the session when claude exits")
        let decision = try #require(try await h.client.timeline(session.id).decisions.first { $0.toolName == "Read" })
        let detail = try await h.client.decision(decision.toolUseId)
        #expect(detail.originalText.contains("Example Domain"))
        #expect(detail.replacementText?.contains("Morph Test Domain") == true)
    }

    @Test func installedHookStaysOutOfGatewaySessions() async throws {
        let h = try await ClaudeHarness.start(steps: [])
        defer { Task { await h.stop() } }
        let project = try h.makeProject(files: ["notes.txt": "Example Domain"])
        let model = ScriptedModel(steps: [.init("Read", ["file_path": project.appendingPathComponent("notes.txt").path])])
        h.mock.setHandler { model.respond($0) }
        _ = try await h.client.createProfile(Profile(name: "read", rules: [Rule(name: "r", match: RuleMatch(tools: ["Read"]), instructions: "rename the domain")]))
        try install(h, project: project, profile: "read")

        // A `diorama run` session in the same folder: the gateway rewrites once, the hook does nothing.
        let launch = try await h.client.createSession(SessionSpec(name: "gw", cwd: project.path, profile: "read"))
        var env = ClaudeHarness.claudeEnvironment(home: h.fakeUserHome)
        env["DIORAMA_HOME"] = h.home.appendingPathComponent("diorama").path
        for (k, v) in launch.environment { env[k] = v }
        let r = try ProcessRunner.run(claudePath!, ["-p", "Read notes.txt", "--output-format", "json", "--allowedTools", "Read"] + launch.claudeArguments,
                                      cwd: project.path, environment: env, timeout: 120)
        #expect(r.exitCode == 0, "stderr: \(r.stderr)")
        #expect(resultText(r.stdout).contains("Morph Test Domain"))
        #expect(h.rewriteCalls == 1)
        #expect(try await h.client.sessions().allSatisfy { $0.via != .hook })
        let main = try await h.client.timeline(launch.session.id).exchanges.filter { $0.requestClass == "main" }
        #expect(main.last?.toolResults.map(\.handling) == [.decidedRewritten], "the gateway must see Claude Code's original result")
    }
}

/// The real Claude Code loading `diorama mcp serve` and calling one of its tools.
@Suite(.serialized, .enabled(if: claudePath != nil && dioramaCLI != nil, "requires the claude CLI and a built diorama CLI"))
struct MCPContractTests {
    @Test func claudeCodeCallsDioramaTools() async throws {
        let h = try await ClaudeHarness.start(steps: [])
        defer { Task { await h.stop() } }
        _ = try await h.client.createProfile(Profile(name: "Docs steer via MCP", rules: [Rule(name: "r", match: RuleMatch(tools: ["WebFetch"]), instructions: "x")]))
        let model = ScriptedModel(steps: [.init("mcp__diorama__list_profiles", [:])])
        h.mock.setHandler { model.respond($0) }
        let project = try h.makeProject(files: [:])
        let config: [String: Any] = ["mcpServers": ["diorama": [
            "command": dioramaCLI!, "args": ["mcp", "serve", "--read-only"],
            "env": ["DIORAMA_HOME": h.home.appendingPathComponent("diorama").path],
        ]]]
        let configJSON = String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
        var env = ClaudeHarness.claudeEnvironment(home: h.fakeUserHome)
        env["ANTHROPIC_BASE_URL"] = h.mock.url.absoluteString
        let r = try ProcessRunner.run(
            claudePath!, ["-p", "Which Diorama profiles exist?", "--output-format", "json", "--mcp-config", configJSON, "--strict-mcp-config",
                          "--allowedTools", "mcp__diorama__list_profiles"],
            cwd: project.path, environment: env, timeout: 120)
        #expect(r.exitCode == 0, "stderr: \(r.stderr)")
        let text = resultText(r.stdout)
        #expect(text.contains("“Docs steer via MCP” v1"), "the tool result should reach the model; got: \(text)")
    }
}

/// Input rules against the real Claude Code: the hook returns the changed input with "ask".
@Suite(.serialized, .enabled(if: claudePath != nil && dioramaCLI != nil, "requires the claude CLI and a built diorama CLI"))
struct InputHookContractTests {
    @Test func changedInputsAskForPermission() async throws {
        let h = try await ClaudeHarness.start(steps: [])
        defer { Task { await h.stop() } }
        let project = try h.makeProject(files: ["Example Domain.txt": "the original file", "Morph Test Domain.txt": "the redirected file"])
        let model = ScriptedModel(steps: [.init("Read", ["file_path": project.appendingPathComponent("Example Domain.txt").path])])
        h.mock.setHandler { model.respond($0) }
        _ = try await h.client.createProfile(Profile(name: "redirect reads", rules: [
            Rule(name: "Redirect", match: RuleMatch(tools: ["Read"], stage: .input), instructions: "rename the domain"),
        ]))
        let command = try HookInstaller.command(cli: dioramaCLI!, config: HookConfig(profile: "redirect reads"))
        try HookInstaller.install(command: command, settings: HookInstaller.projectSettings(project.path))
        var env = ClaudeHarness.claudeEnvironment(home: h.fakeUserHome)
        env["ANTHROPIC_BASE_URL"] = h.mock.url.absoluteString
        env["DIORAMA_HOME"] = h.home.appendingPathComponent("diorama").path
        let r = try ProcessRunner.run(claudePath!, ["-p", "Read the file", "--output-format", "json", "--allowedTools", "Read"], cwd: project.path, environment: env, timeout: 120)
        let text = resultText(r.stdout)
        #expect(r.exitCode == 0, "stderr: \(r.stderr)")
        // Under -p nobody can answer the prompt, so Claude Code denies the call and shows the model our reason.
        #expect(text.contains("Diorama changed this call's input"), "got: \(text)")
        // Diorama recorded and rewrote the input…
        let session = try #require(try await h.client.sessions().first { $0.via == .hook })
        let d = try #require(try await h.client.timeline(session.id).decisions.first { $0.toolUseId.hasPrefix("input:") })
        #expect(d.outcome == .rewritten)
        // …and Claude Code didn't run the changed call unapproved: nobody can approve it under -p.
        #expect(!text.contains("the redirected file"), "a changed input must not run without approval")
    }
}
