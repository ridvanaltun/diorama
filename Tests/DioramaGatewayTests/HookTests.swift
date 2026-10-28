import DioramaClient
import DioramaCore
import Foundation
import Testing
@testable import DioramaGateway

@Suite struct HookEndpointTests {
    let response = #"{"bytes":120,"code":200,"result":"Heading: Example Domain.","url":"https://example.com"}"#

    func event(_ name: String, session: String = "claude-1", tool: String? = nil, id: String? = nil, config: HookConfig = HookConfig()) -> HookEvent {
        HookEvent(
            event: name, claudeSessionId: session, cwd: "/tmp/proj", client: "claude-desktop", toolName: tool, toolUseId: id,
            toolInput: tool == nil ? nil : #"{"url":"https://example.com","prompt":"heading?"}"#, toolResponse: tool == nil ? nil : response, config: config)
    }

    @Test func hookSessionsLifecycle() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        _ = try await env.client.createProfile(Profile(name: "web", rules: [Rule(name: "r", match: RuleMatch(tools: ["WebFetch"]), instructions: "rename")]))
        let config = HookConfig(profile: "web")

        let start = try await env.client.hook(event("SessionStart", config: config))
        let sid = try #require(start.sessionId)
        var info = try await env.client.session(sid)
        #expect(info.via == .hook)
        #expect(info.name == "proj · Desktop")
        #expect(info.profileName == "web")
        #expect(info.claudeSessionIds == ["claude-1"])

        let reply = try await env.client.hook(event("PostToolUse", tool: "WebFetch", id: "toolu_w1", config: config))
        #expect(reply.sessionId == sid)
        #expect(reply.outcome == .rewritten)
        let output = try #require(reply.updatedToolOutput)
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        #expect(obj["result"] as? String == "Heading: Morph Test Domain.")
        #expect(obj["code"] as? Int == 200)

        _ = try await env.client.hook(event("SessionEnd", config: config))
        info = try await env.client.session(sid)
        #expect(info.status == .ended)
        #expect(info.stats.rewrites == 1)

        // Resuming the same Claude session reopens it; the first configuration stays.
        let resumed = try await env.client.hook(event("PostToolUse", tool: "WebFetch", id: "toolu_w2", config: HookConfig()))
        #expect(resumed.sessionId == sid)
        #expect(resumed.outcome == .rewritten)
        #expect(try await env.client.session(sid).status == .active)

        // Hook sessions can't be reached through the gateway.
        let tl = try await env.client.timeline(sid)
        #expect(tl.exchanges.isEmpty)
        #expect(tl.decisions.map(\.toolUseId).sorted() == ["toolu_w1", "toolu_w2"])
        #expect(tl.decisions.first?.toolInput?.contains("example.com") == true)
    }

    @Test func badHookConfigurationStillRecordsTheSession() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        let reply = try await env.client.hook(event("PostToolUse", session: "claude-2", tool: "WebFetch", id: "toolu_b1", config: HookConfig(profile: "missing")))
        #expect(reply.outcome == .unchanged)
        #expect(reply.updatedToolOutput == nil)
        let sid = try #require(reply.sessionId)
        let tl = try await env.client.timeline(sid)
        #expect(tl.events.contains { $0.kind == .anomaly && $0.message.contains("unknown profile") })
        // A SessionEnd for a session Diorama never saw creates nothing.
        #expect(try await env.client.hook(event("SessionEnd", session: "claude-unknown")).sessionId == nil)
    }

    @Test func gatewaySessionsAreMarkedForInstalledHooks() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        let launch = try await env.client.createSession(SessionSpec(name: "g", cwd: "/tmp"))
        #expect(launch.environment["DIORAMA_SESSION"] == launch.session.id)
        #expect(launch.session.via == .gateway)
    }
}

extension HookEndpointTests {
    @Test func hookSessionsRecordWhereTheirHookLives() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("diorama-proj-\(UUID().uuidString)")
        let settings = HookInstaller.projectSettings(project.path)
        try HookInstaller.install(command: "'/x/diorama' hook run", settings: settings)  // installed without the registry
        let sub = project.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        _ = try await env.client.hook(HookEvent(event: "SessionStart", claudeSessionId: "c-reg", cwd: sub.path, config: HookConfig()))
        let registry = HookRegistry(paths: DioramaPaths(home: env.home))
        let deadline = Date().addingTimeInterval(5)
        while !registry.files.contains(settings.path), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(registry.files.contains(settings.path))
    }
}

extension HookEndpointTests {
    @Test func removingTheHookEndsItsActiveSessions() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("diorama-end-\(UUID().uuidString)")
        let settings = HookInstaller.projectSettings(project.path)
        try HookInstaller.install(command: "'/x/diorama' hook run", settings: settings)
        let user = env.home.appendingPathComponent("claude-user-settings.json")
        func start(_ id: String) async throws -> String {
            try #require(try await env.client.hook(HookEvent(event: "SessionStart", claudeSessionId: id, cwd: project.path, config: HookConfig())).sessionId)
        }
        let sid = try await start("c-end")
        DioramaDaemon.endDisconnectedHookSessions(store: env.daemon.store, userSettings: user)
        #expect(try await env.client.session(sid).status == .active, "hook still installed")

        try HookInstaller.uninstall(settings: settings)
        DioramaDaemon.endDisconnectedHookSessions(store: env.daemon.store, userSettings: user)
        #expect(try await env.client.session(sid).status == .ended)
        #expect(try await env.client.timeline(sid).events.contains { $0.message.contains("hook was removed") })
        // If Claude Code does report again (it kept the hook it started with), the session reopens.
        _ = try await env.client.hook(HookEvent(event: "PostToolUse", claudeSessionId: "c-end", cwd: project.path, config: HookConfig()))
        #expect(try await env.client.session(sid).status == .active)
    }
}

@Suite struct HookInstallerTests {
    func tempSettings(_ initial: String?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("diorama-hooks-\(UUID().uuidString)")
        let url = dir.appendingPathComponent(".claude/settings.local.json")
        if let initial {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try initial.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    func load(_ url: URL) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    @Test func installMergesUpdatesAndUninstallsWithoutTouchingOtherSettings() throws {
        let other = #"{"hooks":{"PostToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo mine"}]}]},"permissions":{"allow":["Bash(ls:*)"]}}"#
        let url = try tempSettings(other)
        let cmd1 = try HookInstaller.command(cli: "/Apps/Diorama.app/Contents/Helpers/diorama", config: HookConfig(profile: "Docs steer"))
        #expect(cmd1 == "[ -x '/Apps/Diorama.app/Contents/Helpers/diorama' ] && exec '/Apps/Diorama.app/Contents/Helpers/diorama' hook run --profile 'Docs steer' || true")
        try HookInstaller.install(command: cmd1, settings: url)
        var root = try load(url)
        var hooks = try #require(root["hooks"] as? [String: Any])
        #expect((hooks["PostToolUse"] as? [[String: Any]])?.count == 2)
        #expect((hooks["SessionStart"] as? [[String: Any]])?.count == 1)
        #expect((hooks["SessionEnd"] as? [[String: Any]])?.count == 1)
        #expect(HookInstaller.installedCommand(settings: url) == cmd1)

        // Installing again replaces Diorama's entries instead of adding more.
        let cmd2 = try HookInstaller.command(cli: "/x/diorama", config: HookConfig(prompt: SessionPrompt(text: "it's new", tools: ["WebFetch"], context: .task)))
        #expect(cmd2 == "[ -x '/x/diorama' ] && exec '/x/diorama' hook run --prompt 'it'\\''s new' --prompt-tools 'WebFetch' --prompt-context task || true")
        try HookInstaller.install(command: cmd2, settings: url)
        hooks = try #require(try load(url)["hooks"] as? [String: Any])
        #expect((hooks["PostToolUse"] as? [[String: Any]])?.count == 2)
        #expect(HookInstaller.installedCommand(settings: url) == cmd2)

        #expect(try HookInstaller.uninstall(settings: url))
        root = try load(url)
        #expect(root["permissions"] != nil)
        let left = try #require(root["hooks"] as? [String: [[String: Any]]])
        #expect(left.keys.sorted() == ["PostToolUse"])
        #expect((left["PostToolUse"]?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String == "echo mine")
        #expect(try !HookInstaller.uninstall(settings: url))
    }

    @Test func createsTheFileAndRefusesBrokenJSON() throws {
        let fresh = try tempSettings(nil)
        try HookInstaller.install(command: "'/x/diorama' hook run", settings: fresh)
        #expect(HookInstaller.installedCommand(settings: fresh) == "'/x/diorama' hook run")
        #expect(try HookInstaller.uninstall(settings: fresh))
        #expect(try load(fresh).isEmpty)

        let broken = try tempSettings("{ not json")
        #expect(throws: HookInstaller.Failure.self) { try HookInstaller.install(command: "'/x/diorama' hook run", settings: broken) }
        #expect(try String(contentsOf: broken, encoding: .utf8) == "{ not json")

        #expect(throws: HookInstaller.Failure.self) {
            try HookInstaller.command(cli: "/x/diorama", config: HookConfig(prompt: SessionPrompt(text: "p", stage: .page)))
        }
    }

    @Test func readsTheCLIAndConfigurationBackFromACommand() throws {
        let config = HookConfig(profile: "Docs steer", prompt: SessionPrompt(text: "it's new", tools: ["WebFetch", "Web*"], context: .task, model: "m"), lockdown: .network)
        let command = try HookInstaller.command(cli: "/Apps/Dio rama.app/diorama", config: config)
        #expect(HookInstaller.cliPath(in: command) == "/Apps/Dio rama.app/diorama")
        #expect(HookInstaller.config(in: command) == config)
        #expect(config.summary == "profile \"Docs steer\" · prompt \"it's new\" · lockdown network")
        // Installs from before the existence check call the CLI directly.
        #expect(HookInstaller.cliPath(in: "'/x/diorama' hook run --profile 'p'") == "/x/diorama")
        #expect(HookInstaller.config(in: "'/x/diorama' hook run --profile 'p'") == HookConfig(profile: "p"))
        #expect(HookInstaller.config(in: "echo mine") == nil)
        #expect(HookConfig().summary == "records only (no rules)")
    }

    @Test func theHookDoesNothingOnceTheCLIIsGone() throws {
        let command = try HookInstaller.command(cli: "/nonexistent/diorama", config: HookConfig(lockdown: .network))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
    }

    @Test func registryListsAndRemovesEveryConnectedProject() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("diorama-reg-\(UUID().uuidString)")
        let registry = HookRegistry(paths: DioramaPaths(home: home))
        let user = try tempSettings(#"{"model":"x"}"#)
        let a = try tempSettings(#"{"permissions":{"allow":["Bash(ls)"]}}"#), b = try tempSettings(nil)
        let cli = home.appendingPathComponent("bin/diorama").path  // an executable stands in for the CLI
        try FileManager.default.createDirectory(atPath: (cli as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: cli, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        try HookInstaller.install(command: try HookInstaller.command(cli: cli, config: HookConfig(profile: "p")), settings: a, registry: registry)
        try HookInstaller.install(command: "'/gone/diorama' hook run", settings: b, registry: registry)
        #expect(Set(registry.files) == [a.path, b.path])

        var list = HookInstaller.connected(registry: registry, userSettings: user)
        #expect(list.map(\.settingsFile).sorted() == [a.path, b.path].sorted())
        let pa = try #require(list.first { $0.settingsFile == a.path })
        #expect(pa.folder == a.deletingLastPathComponent().deletingLastPathComponent().path)
        #expect(pa.config?.profile == "p" && !pa.cliMissing && !pa.outdated)
        #expect(try #require(list.first { $0.settingsFile == b.path }).cliMissing)

        // A hook removed by hand drops out of the registry; the user settings count when they have one.
        try HookInstaller.uninstall(settings: b)
        try HookInstaller.install(command: "'/x/diorama' hook run", settings: user)
        list = HookInstaller.connected(registry: registry, userSettings: user)
        #expect(list.map(\.settingsFile).sorted() == [a.path, user.path].sorted())
        #expect(list.first { $0.settingsFile == user.path }?.folder == nil)
        #expect(registry.files == [a.path])

        let (removed, failures) = HookInstaller.uninstallAll(registry: registry, userSettings: user)
        #expect(Set(removed.map(\.path)) == [a.path, user.path] && failures.isEmpty)
        #expect(try load(a)["permissions"] != nil && load(a)["hooks"] == nil)
        #expect(try load(user)["model"] as? String == "x")
        #expect(HookInstaller.connected(registry: registry, userSettings: user).isEmpty && registry.files.isEmpty)
    }

    @Test func locateFindsTheNearestProjectAndTheUserSettings() throws {
        let project = try tempSettings(nil)
        let root = project.deletingLastPathComponent().deletingLastPathComponent()
        let sub = root.appendingPathComponent("src/deep")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let user = try tempSettings(nil)
        #expect(HookInstaller.locate(cwd: sub.path, userSettings: user).isEmpty)
        try HookInstaller.install(command: "'/x/diorama' hook run", settings: project)
        #expect(HookInstaller.locate(cwd: sub.path, userSettings: user).map(\.path) == [project.path])
        try HookInstaller.install(command: "'/x/diorama' hook run", settings: user)
        #expect(HookInstaller.locate(cwd: sub.path, userSettings: user).map(\.path) == [project.path, user.path])
    }

    @Test func claudeTrustFollowsClaudeCodesRules() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("diorama-trust-\(UUID().uuidString)").standardizedFileURL
        let plain = base.appendingPathComponent("work/plain/sub"), repo = base.appendingPathComponent("work/repo")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("src"), withIntermediateDirectories: true)
        let config = base.appendingPathComponent(".claude.json")
        func trust(_ paths: [URL]) throws {
            let projects = Dictionary(uniqueKeysWithValues: paths.map { ($0.path, ["hasTrustDialogAccepted": true]) })
            try JSONSerialization.data(withJSONObject: ["projects": projects]).write(to: config)
        }
        #expect(ClaudeTrust.isTrusted(plain.path, config: config) == nil, "no config, no verdict")
        try trust([])
        #expect(ClaudeTrust.isTrusted(plain.path, config: config) == false)
        // Outside a repository a trusted parent counts.
        try trust([base.appendingPathComponent("work")])
        #expect(ClaudeTrust.isTrusted(plain.path, config: config) == true)
        // Inside one, only folders up to its root do.
        #expect(ClaudeTrust.isTrusted(repo.appendingPathComponent("src").path, config: config) == false)
        try trust([repo])
        #expect(ClaudeTrust.isTrusted(repo.appendingPathComponent("src").path, config: config) == true)
        #expect(ClaudeTrust.advice(for: repo.path).contains("run `claude` in that folder"))

        // Connected projects carry the verdict.
        let registry = HookRegistry(paths: DioramaPaths(home: base.appendingPathComponent("home")))
        try HookInstaller.install(command: "'/x/diorama' hook run", settings: HookInstaller.projectSettings(plain.path), registry: registry)
        try HookInstaller.install(command: "'/x/diorama' hook run", settings: HookInstaller.projectSettings(repo.path), registry: registry)
        let list = HookInstaller.connected(registry: registry, userSettings: base.appendingPathComponent("user.json"), claudeConfig: config)
        #expect(list.first { $0.folder == plain.path }?.notTrusted == true)
        #expect(list.first { $0.folder == repo.path }?.notTrusted == false)
    }
}
