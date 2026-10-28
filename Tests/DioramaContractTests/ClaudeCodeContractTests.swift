import DioramaClient
import DioramaCore
import DioramaEngine
import DioramaRunner
import DioramaStore
import DioramaTestSupport
import Foundation
import Testing
@testable import DioramaGateway

/// Contract tests: the real `claude` CLI talks to the real Diorama daemon, which forwards to a
/// scripted fake model. No account and no network beyond loopback; HOME is a temporary
/// directory so the user's Claude Code configuration is never read or modified.
let claudePath: String? = {
    if let p = ProcessInfo.processInfo.environment["DIORAMA_CLAUDE"] { return p }
    return ClaudeLocator.find(configured: nil)
}()

struct ClaudeHarness {
    let home: URL
    let fakeUserHome: URL
    let mock: MockUpstream
    let model: ScriptedModel
    let daemon: DioramaDaemon
    let client: ControlClient
    let counter = Counter()

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func increment() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }

    static func start(steps: [ScriptedModel.Step], userSettings: [String: Any]? = nil) async throws -> ClaudeHarness {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("diorama-contract-\(UUID().uuidString)")
        let fakeUserHome = root.appendingPathComponent("userhome")
        try FileManager.default.createDirectory(at: fakeUserHome.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        if let userSettings {
            try JSONSerialization.data(withJSONObject: userSettings).write(to: fakeUserHome.appendingPathComponent(".claude/settings.json"))
        }
        let model = ScriptedModel(steps: steps)
        let mock = MockUpstream { req in model.respond(req) }
        try await mock.start()
        let counter = Counter()
        let provider = ScriptedRewriteProvider { req in
            counter.increment()
            return await ScriptedRewriteProvider.replacing("Example Domain", with: "Morph Test Domain").rewrite(req)
        }
        var o = DioramaDaemon.Options(paths: DioramaPaths(home: root.appendingPathComponent("diorama")))
        o.claudeUserSettings = root.appendingPathComponent("diorama").appendingPathComponent("claude-user-settings.json")
        o.port = 0
        o.upstream = mock.url
        o.providerOverride = provider
        o.secrets = MemorySecretStore("sk-ant-test-key-not-real-000000")
        o.judgeOverride = ScriptedJudge.substring
        o.environment = ClaudeHarness.claudeEnvironment(home: fakeUserHome)
        let d = try DioramaDaemon(options: o)
        _ = try await d.start()
        Task { _ = try? await d.run() }
        let info = try #require(DaemonInfo.read(from: o.paths.daemonInfo))
        var h = ClaudeHarness(home: root, fakeUserHome: fakeUserHome, mock: mock, model: model, daemon: d, client: ControlClient(info: info))
        h.counterRef = counter
        return h
    }

    var counterRef: Counter?
    var rewriteCalls: Int { counterRef?.value ?? 0 }

    static func claudeEnvironment(home: URL) -> [String: String] {
        let pe = ProcessInfo.processInfo.environment
        return [
            "PATH": pe["PATH"] ?? "/usr/bin:/bin", "HOME": home.path, "USER": NSUserName(), "LOGNAME": NSUserName(),
            "TMPDIR": NSTemporaryDirectory(), "TERM": "dumb", "ANTHROPIC_API_KEY": "sk-ant-api03-dummy-key-for-contract-tests",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "DISABLE_AUTOUPDATER": "1",
        ]
    }

    /// Runs `claude -p` in `cwd` through the given session launch; returns the JSON result text.
    func runClaude(_ launch: SessionLaunch, prompt: String, cwd: URL, extraArgs: [String] = []) async throws -> (exit: Int32, stdout: String, stderr: String) {
        var env = Self.claudeEnvironment(home: fakeUserHome)
        for (k, v) in launch.environment { env[k] = v }
        let args = ["-p", prompt, "--output-format", "json"] + extraArgs + launch.claudeArguments
        let r = try await ProcessRunner.runAsync(claudePath!, args, cwd: cwd.path, environment: env, timeout: 120)
        return (r.exitCode, r.stdout, r.stderr)
    }

    func stop() async {
        await daemon.stop()
        await mock.stop()
    }

    func makeProject(files: [String: String]) throws -> URL {
        let dir = home.appendingPathComponent("project-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, content) in files { try content.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        return dir
    }
}

func resultText(_ stdout: String) -> String {
    guard let data = stdout.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return stdout }
    return obj["result"] as? String ?? stdout
}

@Suite(.serialized, .enabled(if: claudePath != nil, "requires the claude CLI"))
struct ClaudeCodeContractTests {
    @Test func realClaudeCodeSeesRewrittenToolResultsConsistently() async throws {
        let h = try await ClaudeHarness.start(steps: [.init("Read", ["file_path": "PLACEHOLDER"]), .init("Read", ["file_path": "PLACEHOLDER"])])
        defer { Task { await h.stop() } }
        let project = try h.makeProject(files: ["notes.txt": "Example Domain\nsecond line"])
        // Steps need absolute paths; rebuild the model with the real path.
        let path = project.appendingPathComponent("notes.txt").path
        let model = ScriptedModel(steps: [.init("Read", ["file_path": path]), .init("Bash", ["command": "echo Example Domain from bash", "description": "echo"])])
        h.mock.setHandler { model.respond($0) }
        _ = try await h.client.createProfile(Profile(name: "read-bash", rules: [Rule(name: "r", match: RuleMatch(tools: ["Read", "Bash"]), instructions: "rename the domain")]))
        let launch = try await h.client.createSession(SessionSpec(name: "contract", cwd: project.path, profile: "read-bash"))
        let r = try await h.runClaude(launch, prompt: "Read notes.txt then echo", cwd: project, extraArgs: ["--allowedTools", "Read,Bash(echo:*)"])
        #expect(r.exit == 0, "stderr: \(r.stderr)")
        let text = resultText(r.stdout)
        #expect(text.contains("MODEL SAW:"), "stdout: \(r.stdout)")
        #expect(text.contains("Morph Test Domain"))
        #expect(!text.contains("Example Domain"))

        // Every main request after the first tool call carried the identical rewritten bytes.
        let mains = model.mainRequests
        #expect(mains.count == 3)
        let tl = try await h.client.timeline(launch.session.id)
        let mainExchanges = tl.exchanges.filter { $0.requestClass == "main" }
        #expect(mainExchanges.count == 3, "hint headers should label main requests; got \(tl.exchanges.map { $0.requestClass ?? "nil" })")
        #expect(mainExchanges[1].toolResults.map(\.handling) == [.decidedRewritten])
        #expect(mainExchanges[2].toolResults.map(\.handling) == [.replayedRewritten, .decidedRewritten])
        #expect(h.rewriteCalls == 2)
        #expect(h.mock.requests.allSatisfy { !$0.uri.hasPrefix("/s/") }, "session prefix must be stripped before forwarding")
        let readDecision = try #require(tl.decisions.first { $0.toolName == "Read" })
        let detail = try await h.client.decision(readDecision.toolUseId)
        #expect(detail.originalText.contains("Example Domain"))
        #expect(detail.replacementText?.contains("Morph Test Domain") == true)
    }

    @Test func settingsFlagWinsOverUserSettingsBaseURL() async throws {
        // The fake user's settings point Claude Code at a dead gateway; Diorama's --settings must win.
        let h = try await ClaudeHarness.start(steps: [], userSettings: ["env": ["ANTHROPIC_BASE_URL": "http://127.0.0.1:9"]])
        defer { Task { await h.stop() } }
        let project = try h.makeProject(files: [:])
        let launch = try await h.client.createSession(SessionSpec(name: "precedence", cwd: project.path))
        let r = try await h.runClaude(launch, prompt: "hello", cwd: project)
        #expect(r.exit == 0, "stderr: \(r.stderr)")
        #expect(resultText(r.stdout).contains("MODEL SAW"))
        #expect(!h.mock.requests.isEmpty)
        // Diorama never edits the user's Claude Code settings.
        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: h.fakeUserHome.appendingPathComponent(".claude/settings.json"))) as? [String: Any]
        #expect((after?["env"] as? [String: String]) == ["ANTHROPIC_BASE_URL": "http://127.0.0.1:9"])
    }

    @Test func networkLockdownDeniesShellNetworkTools() async throws {
        let h = try await ClaudeHarness.start(steps: [.init("Bash", ["command": "curl https://example.com", "description": "fetch"])])
        defer { Task { await h.stop() } }
        let project = try h.makeProject(files: [:])
        let launch = try await h.client.createSession(SessionSpec(name: "lockdown", cwd: project.path, lockdown: .network))
        let r = try await h.runClaude(launch, prompt: "fetch example.com with curl", cwd: project, extraArgs: ["--allowedTools", "Bash"])
        #expect(r.exit == 0, "stderr: \(r.stderr)")
        let text = resultText(r.stdout)
        #expect(text.contains("[is_error]"), "the curl call must be refused; got: \(text)")
        #expect(!text.contains("Example Domain"))
    }

    @Test func toolResultShapesForBuiltInTools() async throws {
        // Records how Claude Code encodes tool results (documented in docs/poc-findings.md).
        let h = try await ClaudeHarness.start(steps: [])
        defer { Task { await h.stop() } }
        let project = try h.makeProject(files: ["a.txt": "hello"])
        // 1×1 transparent PNG.
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=")!
        try png.write(to: project.appendingPathComponent("pixel.png"))
        let model = ScriptedModel(steps: [
            .init("Read", ["file_path": project.appendingPathComponent("a.txt").path]),
            .init("Read", ["file_path": project.appendingPathComponent("pixel.png").path]),
            .init("Bash", ["command": "echo shape-test", "description": "echo"]),
            .init("Grep", ["pattern": "hello", "path": project.path]),
        ])
        h.mock.setHandler { model.respond($0) }
        _ = try await h.client.createProfile(Profile(name: "all", rules: [Rule(name: "r", match: RuleMatch(tools: ["*"]), instructions: "x")]))
        let launch = try await h.client.createSession(SessionSpec(name: "shapes", cwd: project.path, profile: "all"))
        let r = try await h.runClaude(launch, prompt: "go", cwd: project, extraArgs: ["--allowedTools", "Read,Bash(echo:*),Grep"])
        #expect(r.exit == 0, "stderr: \(r.stderr)")
        let last = try #require(model.mainRequests.last)
        var shapes: [String: String] = [:]
        var names: [String: String] = [:]
        for m in last["messages"] as? [[String: Any]] ?? [] {
            for b in m["content"] as? [[String: Any]] ?? [] {
                if b["type"] as? String == "tool_use" { names[b["id"] as! String] = b["name"] as? String }
                if b["type"] as? String == "tool_result", let id = b["tool_use_id"] as? String {
                    let c = b["content"]
                    let kind = c is String ? "string" : (c as? [[String: Any]]).map { "blocks:" + $0.compactMap { $0["type"] as? String }.joined(separator: "+") } ?? "absent"
                    shapes[names[id] ?? id, default: ""] += (shapes[names[id] ?? id] == nil ? "" : ",") + kind
                }
            }
        }
        print("TOOL_RESULT_SHAPES \(shapes.sorted { $0.key < $1.key })")
        #expect(shapes["Bash"] != nil)
        #expect(shapes["Read"]?.contains("image") == true, "image reads should be block content: \(shapes)")
        // The image result must be forwarded untouched (only text segments are rewritten).
        let tl = try await h.client.timeline(launch.session.id)
        #expect(!tl.decisions.isEmpty)
    }

    /// Needs network access (Claude Code's WebFetch downloads example.com). Skipped when
    /// DIORAMA_OFFLINE is set.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIORAMA_OFFLINE"] == nil))
    func preExtractionRewritesThePageBeforeWebFetchSummarizes() async throws {
        let h = try await ClaudeHarness.start(steps: [.init("WebFetch", ["url": "https://example.com", "prompt": "What is the main heading?"])],
                                              userSettings: ["skipWebFetchPreflight": true])
        defer { Task { await h.stop() } }
        let project = try h.makeProject(files: [:])
        _ = try await h.client.createProfile(Profile(name: "page", rules: [
            Rule(name: "Rename on page", match: RuleMatch(tools: ["WebFetch"], input: ["url": "example\\.com"], stage: .page), instructions: "rename"),
        ]))
        let launch = try await h.client.createSession(SessionSpec(name: "page", cwd: project.path, profile: "page"))
        let r = try await h.runClaude(launch, prompt: "Fetch example.com", cwd: project, extraArgs: ["--allowedTools", "WebFetch"])
        #expect(r.exit == 0, "stderr: \(r.stderr)")
        let text = resultText(r.stdout)
        // The summarizing model received the rewritten page, and Claude got its summary.
        #expect(text.contains("PAGE SAW:"), "stdout: \(r.stdout)")
        #expect(text.contains("Morph Test Domain"))
        #expect(!text.contains("Example Domain"))
        let tl = try await h.client.timeline(launch.session.id)
        let page = try #require(tl.decisions.first { $0.toolUseId.hasPrefix("page:toolu_") })
        #expect(page.outcome == .rewritten)
        let detail = try await h.client.decision(page.toolUseId)
        #expect(detail.toolInput?.contains("example.com") == true)
        #expect(tl.exchanges.contains { $0.requestClass == "auxiliary" && $0.toolResults.contains { $0.handling == .decidedRewritten } })
    }

    @Test func experimentRunnerEndToEndWithRealClaude() async throws {
        let h = try await ClaudeHarness.start(steps: [])
        defer { Task { await h.stop() } }
        let project = try h.makeProject(files: ["notes.txt": "Example Domain"])
        // The trial runs in a clone, so the script reads the file by relative path.
        let model = ScriptedModel(steps: [.init("Read", ["file_path": "notes.txt"])])
        h.mock.setHandler { model.respond($0) }
        try await h.client.saveSettings(DioramaSettings(claudePath: claudePath))
        let def = ExperimentDefinition(
            name: "contract experiment", task: "Read notes.txt and repeat it", projectPath: project.path,
            claude: ClaudeRunOptions(allowedTools: ["Read"], maxTurns: 5, isolateConfiguration: true, timeoutSeconds: 120),
            variants: [ExperimentVariant(key: "control", name: "Control"),
                       ExperimentVariant(key: "steered", name: "Steered", prompt: SessionPrompt(text: "rename the domain", tools: ["Read"]))],
            trialsPerVariant: 2, concurrency: 2, treatment: .frozen, seed: 7, judge: JudgeConfig(model: "claude-haiku-5-5"))
        let exp = try await h.client.createExperiment(def)
        let pending = try await h.client.prepareRun(experimentId: exp.id)
        let est = try #require(pending.estimate)
        #expect(est.trials == 4)
        await #expect(throws: ClientError.self) { _ = try await h.client.startRun(pending.id, confirmationToken: "wrong") }
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
        // LLM judge (scripted here): steered answers adopted the change, controls did not.
        #expect(steered.judgeAdopted?.count == 2)
        #expect(control.judgeAdopted?.count == 0)
        #expect(cmp.caveats.contains { $0.contains("LLM-judge") })
        // Frozen treatment: both steered trials reused one rewrite.
        #expect(h.rewriteCalls == 1)
        // Isolation: the source project is untouched and trial clones are cleaned up.
        #expect(try String(contentsOf: project.appendingPathComponent("notes.txt"), encoding: .utf8) == "Example Domain")
        for t in cmp.trials {
            #expect(t.manifest?.claudeVersion?.isEmpty == false)
            #expect(t.manifest?.seed == 7)
            if let w = t.workdir { #expect(!FileManager.default.fileExists(atPath: w)) }
        }
        let md = try await h.client.report(pending.id, format: "md")
        #expect(md.contains("Heuristic signals (interpretations, not facts)"))
        #expect(md.contains("not proof of cause"))
        let json = try await h.client.report(pending.id, format: "json")
        #expect(json.contains("diorama-experiment-bundle/1"))
    }
}
