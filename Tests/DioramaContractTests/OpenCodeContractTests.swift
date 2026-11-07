import DioramaClient
import DioramaCore
import DioramaEngine
import DioramaRunner
import DioramaStore
import DioramaTestSupport
import Foundation
import Testing
@testable import DioramaGateway

/// Contract tests with the real `opencode` CLI (2.x): it talks to the real daemon, which forwards
/// to a scripted fake model. OpenCode's folders live in a temporary home, so the user's OpenCode
/// configuration, sessions and credentials are never read or changed.
let opencodePath: String? = {
    if let p = ProcessInfo.processInfo.environment["DIORAMA_OPENCODE"] { return p }
    return OpenCodeLocator.find()
}()

@Suite(.serialized, .enabled(if: opencodePath != nil, "requires the opencode CLI"))
struct OpenCodeContractTests {
    /// Runs `opencode run` in `cwd` through the session launch, as `diorama run --agent opencode` would.
    func runOpenCode(_ h: ClaudeHarness, _ launch: SessionLaunch, prompt: String, cwd: URL) async throws -> (exit: Int32, stdout: String, stderr: String) {
        var env = h.daemon.options.environment
        for (k, v) in launch.environment { env[k] = v }
        let args = try OpenCodeLaunch.arguments(user: ["run", "--auto", "--format", "json", "-m", "anthropic/claude-sonnet-4-5", prompt], launch: launch.claudeArguments).get()
        let r = try await ProcessRunner.runAsync(opencodePath!, args, cwd: cwd.path, environment: env, timeout: 120)
        return (r.exitCode, r.stdout, r.stderr)
    }

    @Test func realOpenCodeSeesRewrittenToolResultsConsistently() async throws {
        let h = try await ClaudeHarness.start(steps: [], openCode: true)
        defer { Task { await h.stop() } }
        let project = try h.makeProject(files: ["notes.txt": "Example Domain\nsecond line"])
        let model = ScriptedModel(steps: [.init("read", ["path": "notes.txt"]), .init("read", ["path": "notes.txt"])])
        h.mock.setHandler { model.respond($0) }
        // A rule written for Claude Code's tool name.
        _ = try await h.client.createProfile(Profile(name: "files", rules: [Rule(name: "r", match: RuleMatch(tools: ["Read"]), instructions: "rename the domain")]))
        let launch = try await h.client.createSession(SessionSpec(name: "oc contract", cwd: project.path, profile: "files", agent: .opencode))
        let r = try await runOpenCode(h, launch, prompt: "Read notes.txt twice", cwd: project)
        #expect(r.exit == 0, "stderr: \(r.stderr)")
        let output = OpenCodeOutput.parse(r.stdout)
        #expect(output.finalOutput.contains("MODEL SAW:"), "stdout: \(r.stdout)")
        #expect(output.finalOutput.contains("Morph Test Domain"))
        #expect(!output.finalOutput.contains("Example Domain"))
        #expect(output.toolCalls == ["read": 2])

        let tl = try await h.client.timeline(launch.session.id)
        #expect(tl.session.isOpenCode)
        #expect(tl.session.claudeSessionIds.first?.hasPrefix("ses_") == true)
        let withResults = tl.exchanges.filter { !$0.toolResults.isEmpty }
        #expect(withResults.map { $0.toolResults.map(\.handling) } == [[.decidedRewritten], [.replayedRewritten, .decidedRewritten]])
        #expect(h.rewriteCalls == 2)
        #expect(tl.decisions.allSatisfy { $0.toolName == "read" })
    }

    @Test func experimentRunnerEndToEndWithRealOpenCode() async throws {
        let h = try await ClaudeHarness.start(steps: [], openCode: true)
        defer { Task { await h.stop() } }
        let project = try h.makeProject(files: ["notes.txt": "Example Domain"])
        // The shell call isn't allowed, so OpenCode doesn't offer the tool and refuses the call.
        let model = ScriptedModel(steps: [.init("read", ["path": "notes.txt"]), .init("shell", ["command": "echo hi", "description": "echo"])])
        h.mock.setHandler { model.respond($0) }
        let def = ExperimentDefinition(
            name: "opencode contract experiment", task: "Read notes.txt and repeat it", projectPath: project.path,
            claude: ClaudeRunOptions(model: "claude-sonnet-4-5", allowedTools: ["Read"], maxTurns: 5, isolateConfiguration: true, timeoutSeconds: 120),
            variants: [ExperimentVariant(key: "control", name: "Control"),
                       ExperimentVariant(key: "steered", name: "Steered", prompt: SessionPrompt(text: "rename the domain", tools: ["Read"]))],
            trialsPerVariant: 2, concurrency: 2, treatment: .frozen, seed: 11, judge: JudgeConfig(model: "claude-haiku-5-5"), agent: .opencode)
        let exp = try await h.client.createExperiment(def)
        let pending = try await h.client.prepareRun(experimentId: exp.id)
        let est = try #require(pending.estimate)
        #expect(est.notes.contains { $0.contains("OpenCode usage") })
        _ = try await h.client.startRun(pending.id, confirmationToken: est.confirmationToken)
        await h.daemon.runner.waitForRun(pending.id)
        let cmp = try await h.client.comparison(pending.id)
        #expect(cmp.run.status == .completed)
        for t in cmp.trials { #expect(t.status == .succeeded, "trial \(t.order) \(t.variantKey): \(t.error ?? "")") }
        let control = try #require(cmp.variants.first { $0.variantKey == "control" })
        let steered = try #require(cmp.variants.first { $0.variantKey == "steered" })
        #expect(control.rewritesApplied.mean == 0)
        #expect(steered.rewritesApplied.mean == 1)
        #expect(steered.echoedRewrittenContent.count == 2)
        #expect(control.echoedRewrittenContent.count == 0)
        #expect(steered.judgeAdopted?.count == 2)
        #expect(control.judgeAdopted?.count == 0)
        #expect(h.rewriteCalls == 1, "frozen treatment: one rewrite for both steered trials")
        #expect(try String(contentsOf: project.appendingPathComponent("notes.txt"), encoding: .utf8) == "Example Domain")
        for t in cmp.trials {
            let facts = try #require(t.facts)
            #expect(facts.toolCalls == ["read": 1, "shell": 1])
            #expect(facts.numTurns == 3)
            #expect(facts.usage.inputTokens > 0, "usage comes from the gateway's records")
            // OpenCode removes a denied tool from the model's list, so the call finds no such tool.
            #expect(facts.finalOutput.contains(#"No tool named \"shell\""#), "allowedTools became OpenCode permissions: \(facts.finalOutput)")
            let manifest = try #require(t.manifest)
            #expect(manifest.agent == .opencode)
            #expect(manifest.claudePath.hasSuffix("opencode") || manifest.claudePath.hasSuffix("opencode-cli"))
            #expect(manifest.claudeVersion?.isEmpty == false)
            #expect(manifest.arguments.prefix(5) == ["run", "--standalone", "--auto", "--format", "json"])
            let config = try #require(manifest.environment[OpenCodeLaunch.configVariable])
            #expect(config.contains("/s/<session-token>/v1") && !config.contains(launchTokenFragment(config)))
            #expect(manifest.environment["XDG_CONFIG_HOME"] == "<empty folder per trial>")
            if let w = t.workdir { #expect(!FileManager.default.fileExists(atPath: w)) }
        }
        let offered = Set(model.mainRequests.flatMap { ($0["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String } })
        #expect(offered.contains("read") && !offered.contains("shell"), "only allowed tools are offered: \(offered.sorted())")
        // Trial sessions are recorded as OpenCode sessions.
        let sid = try #require(cmp.trials.first?.sessionId)
        #expect(try await h.client.session(sid).isOpenCode)
    }

    @Test(.enabled(if: dioramaCLI != nil, "requires a built diorama CLI"))
    func pluginRewritesAndRecordsTheModelsReplies() async throws {
        let h = try await ClaudeHarness.start(steps: [], openCode: true)
        defer { Task { await h.stop() } }
        let project = try h.makeProject(files: ["notes.txt": "Example Domain"])
        let model = ScriptedModel(steps: [.init("read", ["path": "notes.txt"])])
        h.mock.setHandler { model.respond($0) }
        _ = try await h.client.createProfile(Profile(name: "files", rules: [Rule(name: "r", match: RuleMatch(tools: ["Read"]), instructions: "rename the domain")]))
        let home = h.home.appendingPathComponent("diorama")
        try HookInstaller.install(cli: dioramaCLI!, config: HookConfig(profile: "files"), settings: OpenCodePlugin.projectFile(project.path),
                                  registry: HookRegistry(paths: DioramaPaths(home: home)))

        // OpenCode talking straight to the (mock) model, like OpenCode Desktop: only the plugin involves Diorama.
        var env = h.daemon.options.environment
        env["DIORAMA_HOME"] = home.path
        env[OpenCodeLaunch.configVariable] = #"{"providers":{"anthropic":{"settings":{"baseURL":"\#(h.mock.url.absoluteString)/v1"}}}}"#
        let r = try await ProcessRunner.runAsync(opencodePath!, ["run", "--standalone", "--auto", "--format", "json", "-m", "anthropic/claude-sonnet-4-5", "Read notes.txt"],
                                                 cwd: project.path, environment: env, timeout: 120)
        #expect(r.exitCode == 0, "stderr: \(r.stderr)")
        let output = OpenCodeOutput.parse(r.stdout).finalOutput
        #expect(output.contains("Morph Test Domain") && !output.contains("Example Domain"), "stdout: \(r.stdout)")

        let session = try #require(try await h.client.sessions().first { $0.via == .hook })
        #expect(session.isOpenCode && session.name.hasSuffix("· OpenCode"))
        #expect(session.status == .ended, "the plugin ends its sessions when OpenCode's server stops")
        // The plugin's transcript lets Diorama see what the model did with the rewrite.
        let transcript = try #require(try h.daemon.store.session(id: session.id)?.transcriptPath)
        #expect(transcript.hasPrefix(OpenCodePlugin.transcriptsDirectory(home: home).path))
        let lines = try String(contentsOfFile: transcript, encoding: .utf8).split(separator: "\n")
        #expect(lines.first?.contains(#""type":"user""#) == true && lines.first?.contains("Read notes.txt") == true, "\(lines)")
        let impact = try #require(try await h.client.impact(session.id).first)
        #expect(impact.status != .notVisible)
        #expect(impact.signals.contains(.used), "evidence: \(impact.evidence) transcript: \(lines.joined(separator: " || "))")
    }

    /// A session token in `s`, if one slipped through (a NUL otherwise, which no configuration contains).
    func launchTokenFragment(_ s: String) -> String {
        s.range(of: #"/s/[0-9a-f]{32}"#, options: .regularExpression).map { String(s[$0]) } ?? "\u{0}"
    }
}
