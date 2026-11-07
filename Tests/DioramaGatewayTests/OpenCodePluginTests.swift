import DioramaClient
import DioramaCore
import Foundation
import Testing
@testable import DioramaGateway

@Suite struct OpenCodePluginInstallTests {
    func tempProject() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("diorama-ocplugin-\(UUID().uuidString)").standardizedFileURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func installWritesOnlyTheCLIAndAnIdIntoTheProject() throws {
        let home = try tempProject(), project = try tempProject()
        let registry = HookRegistry(paths: DioramaPaths(home: home))
        let file = OpenCodePlugin.projectFile(project.path)
        #expect(file.path == project.path + "/.opencode/plugins/diorama/index.ts")
        let config = HookConfig(profile: "Docs steer", prompt: SessionPrompt(text: "Say v2 is deprecated", tools: ["webfetch"]), lockdown: .network)
        let cli = "/Applications/Dio's/diorama"
        try HookInstaller.install(cli: cli, config: config, settings: file, registry: registry)

        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("deprecated") && !text.contains("Docs steer"))
        #expect(text.contains(#"const CLI = "/Applications/Dio's/diorama""#))
        #expect(text.contains("const LOCKDOWN = true"))
        let command = try #require(HookInstaller.installedCommand(settings: file))
        let id = try #require(HookInstaller.configId(in: command))
        #expect(text.contains(#""--config", "\#(id)""#))
        #expect(HookInstaller.cliPath(in: command) == cli)
        #expect(HookInstaller.resolvedConfig(in: command, configs: registry.configs) == config)
        #expect(registry.files == [file.path])

        // Reinstalling keeps the id and rewrites the lockdown switch.
        try HookInstaller.install(cli: cli, config: HookConfig(profile: "Docs steer"), settings: file, registry: registry)
        #expect(HookInstaller.installedCommand(settings: file).flatMap(HookInstaller.configId(in:)) == id)
        #expect(try String(contentsOf: file, encoding: .utf8).contains("const LOCKDOWN = false"))

        #expect(try HookInstaller.uninstall(settings: file, registry: registry))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent(".opencode").path), "the empty folders it created go too")
        #expect(FileManager.default.fileExists(atPath: project.path))
        #expect(registry.configs.get(id) == nil && registry.files.isEmpty)
        #expect(try !HookInstaller.uninstall(settings: file, registry: registry))
    }

    @Test func pageRulesAreRefused() throws {
        let registry = HookRegistry(paths: DioramaPaths(home: try tempProject()))
        let file = OpenCodePlugin.projectFile(try tempProject().path)
        #expect(throws: HookInstaller.Failure.self) {
            try HookInstaller.install(cli: "/x/diorama", config: HookConfig(prompt: SessionPrompt(text: "x", stage: .page)), settings: file, registry: registry)
        }
    }

    @Test func aFileThatIsNotDioramasIsLeftAlone() throws {
        let file = OpenCodePlugin.projectFile(try tempProject().path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "export default {}\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(HookInstaller.installedCommand(settings: file) == nil)
        #expect(try !HookInstaller.uninstall(settings: file))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func connectedLocateAndUninstallAllIncludePlugins() throws {
        let home = try tempProject(), project = try tempProject(), claudeProject = try tempProject()
        let registry = HookRegistry(paths: DioramaPaths(home: home))
        let user = home.appendingPathComponent("user-settings.json")
        let userPlugin = home.appendingPathComponent("oc/plugins/diorama/index.ts")
        let cli = home.appendingPathComponent("bin/diorama").path
        try FileManager.default.createDirectory(atPath: (cli as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: cli, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])

        let plugin = OpenCodePlugin.projectFile(project.path)
        let ownConfig = project.appendingPathComponent(".opencode/opencode.json")
        try FileManager.default.createDirectory(at: ownConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{}".write(to: ownConfig, atomically: true, encoding: .utf8)
        try HookInstaller.install(cli: cli, config: HookConfig(profile: "p"), settings: plugin, registry: registry)
        try HookInstaller.install(cli: cli, config: HookConfig(), settings: HookInstaller.projectSettings(claudeProject.path), registry: registry)
        try HookInstaller.install(cli: cli, config: HookConfig(), settings: userPlugin, registry: registry)

        let list = HookInstaller.connected(registry: registry, userSettings: user, userPlugin: userPlugin)
        let p = try #require(list.first { $0.settingsFile == plugin.path })
        #expect(p.agent == .opencode && p.folder == project.path && p.config?.profile == "p" && !p.cliMissing && !p.outdated && !p.notTrusted)
        #expect(list.first { $0.settingsFile == userPlugin.path }.map { $0.agent == .opencode && $0.folder == nil } == true)
        #expect(list.first { $0.folder == claudeProject.path }?.agent == .claude)

        let sub = project.appendingPathComponent("src/deep")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        #expect(HookInstaller.locate(cwd: sub.path, userSettings: user, userPlugin: userPlugin).map(\.path) == [plugin.path, userPlugin.path])

        let (removed, failures) = HookInstaller.uninstallAll(registry: registry, userSettings: user, userPlugin: userPlugin)
        #expect(failures.isEmpty && removed.count == 3)
        #expect(!FileManager.default.fileExists(atPath: plugin.path) && !FileManager.default.fileExists(atPath: userPlugin.path))
        #expect(FileManager.default.fileExists(atPath: ownConfig.path), "the project's own .opencode folder stays")
        #expect(HookInstaller.locate(cwd: sub.path, userSettings: user, userPlugin: userPlugin).isEmpty)
    }

    @Test func pluginsWriteTranscriptsIntoTheDataFolderAndAreRefreshedOnUpgrade() throws {
        let home = try tempProject(), project = try tempProject()
        let registry = HookRegistry(paths: DioramaPaths(home: home))
        let file = OpenCodePlugin.projectFile(project.path)
        try HookInstaller.install(cli: "/x/diorama", config: HookConfig(profile: "p", lockdown: .network), settings: file, registry: registry)
        let transcripts = OpenCodePlugin.transcriptsDirectory(home: home)
        #expect(try String(contentsOf: file, encoding: .utf8).contains(#"const TRANSCRIPTS = "\#(transcripts.path)""#))
        #expect(!OpenCodePlugin.refresh(file: file, configs: registry.configs, transcripts: transcripts), "already current")

        // A plugin from an earlier version: same first line (CLI and id), older body.
        let firstLine = try String(contentsOf: file, encoding: .utf8).split(separator: "\n", maxSplits: 1)[0]
        try (firstLine + "\nexport default { id: \"diorama\", setup() {} }\n").write(to: file, atomically: true, encoding: .utf8)
        #expect(OpenCodePlugin.refresh(file: file, configs: registry.configs, transcripts: transcripts))
        let refreshed = try String(contentsOf: file, encoding: .utf8)
        #expect(refreshed.contains("const LOCKDOWN = true") && refreshed.contains("transcript_path"))
        #expect(HookInstaller.installedCommand(settings: file).flatMap(HookInstaller.configId(in:)) == HookInstaller.configId(in: String(firstLine)))
    }

    @Test func oldTranscriptsArePruned() throws {
        let dir = try tempProject()
        let old = dir.appendingPathComponent("ses_old.jsonl"), fresh = dir.appendingPathComponent("ses_new.jsonl"), other = dir.appendingPathComponent("notes.txt")
        for f in [old, fresh, other] { try "{}".write(to: f, atomically: true, encoding: .utf8) }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-40 * 86_400)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-40 * 86_400)], ofItemAtPath: other.path)
        DioramaDaemon.pruneTranscripts(in: dir, olderThanDays: 30)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path) && FileManager.default.fileExists(atPath: other.path))
    }

    @Test func userFileFollowsXDGConfigHome() {
        #expect(OpenCodePlugin.userFile(environment: ["HOME": "/Users/a"]).path == "/Users/a/.config/opencode/plugins/diorama/index.ts")
        #expect(OpenCodePlugin.userFile(environment: ["HOME": "/Users/a", "XDG_CONFIG_HOME": "/cfg"]).path == "/cfg/opencode/plugins/diorama/index.ts")
    }
}

@Suite struct OpenCodeHookEndpointTests {
    /// A `read` result as OpenCode's `execute.after` hook hands it to the plugin.
    let readResult = #"{"output":{"type":"file","uri":"file:///p/facts.txt","name":"facts.txt","content":"Example Domain\n","encoding":"utf8","mime":"text/plain"},"content":[{"type":"text","text":"Read file /p/facts.txt, lines 1-1\n1: Example Domain"}],"metadata":{"truncated":false}}"#

    func event(_ name: String, tool: String, id: String, input: String, response: String? = nil, config: HookConfig) -> HookEvent {
        HookEvent(event: name, claudeSessionId: "ses_oc_1", cwd: "/tmp/ocproj", client: HookEvent.openCodeClient, toolName: tool, toolUseId: id,
                  toolInput: input, toolResponse: response, config: config)
    }

    @Test func rewritesWhatTheModelReadsAndKeepsTheRestOfTheResult() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        _ = try await env.client.createProfile(Profile(name: "files", rules: [Rule(name: "r", match: RuleMatch(tools: ["Read"]), instructions: "rename")]))
        let reply = try await env.client.hook(event("PostToolUse", tool: "read", id: "toolu_oc_r1", input: #"{"path":"/p/facts.txt"}"#, response: readResult,
                                                    config: HookConfig(profile: "files")))
        #expect(reply.outcome == .rewritten)
        let output = try #require(reply.updatedToolOutput)
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let content = try #require(obj["content"] as? [[String: Any]])
        #expect(content.first?["text"] as? String == "Read file /p/facts.txt, lines 1-1\n1: Morph Test Domain")
        #expect((obj["output"] as? [String: Any])?["name"] as? String == "facts.txt")
        #expect((obj["metadata"] as? [String: Any])?["truncated"] as? Bool == false)

        let info = try await env.client.session(try #require(reply.sessionId))
        #expect(info.via == .hook && info.agent == .opencode && info.isOpenCode)
        #expect(info.name == "ocproj · OpenCode")
        #expect(info.claudeSessionIds == ["ses_oc_1"])
        let detail = try await env.client.decision("toolu_oc_r1")
        #expect(detail.originalText == "Read file /p/facts.txt, lines 1-1\n1: Example Domain")
    }

    @Test func lockdownDeniesNetworkCommandsAndInputRulesStayOff() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        _ = try await env.client.createProfile(Profile(name: "inputs", rules: [
            Rule(name: "i", match: RuleMatch(tools: ["*"], stage: .input), instructions: "change the input"),
        ]))
        let config = HookConfig(profile: "inputs", lockdown: .network)
        let denied = try await env.client.hook(event("PreToolUse", tool: "shell", id: "toolu_oc_s1", input: #"{"command":"timeout 5 curl -s https://example.com"}"#, config: config))
        #expect(denied.deny?.contains("curl") == true)
        #expect(denied.deny?.contains("webfetch") == true)
        let allowed = try await env.client.hook(event("PreToolUse", tool: "shell", id: "toolu_oc_s2", input: #"{"command":"ls"}"#, config: config))
        #expect(allowed.deny == nil && allowed.updatedInput == nil && allowed.outcome == nil)
        let tl = try await env.client.timeline(try #require(allowed.sessionId))
        #expect(tl.decisions.isEmpty, "input rules aren't applied (or recorded) for OpenCode")
    }

    @Test func removingThePluginEndsItsSessions() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("diorama-ocend-\(UUID().uuidString)")
        let plugin = OpenCodePlugin.projectFile(project.path)
        try HookInstaller.install(cli: "/x/diorama", config: HookConfig(), settings: plugin, registry: HookRegistry(paths: DioramaPaths(home: env.home)))
        let reply = try await env.client.hook(HookEvent(event: "PostToolUse", claudeSessionId: "ses_oc_end", cwd: project.path, client: HookEvent.openCodeClient,
                                                        toolName: "read", toolUseId: "toolu_oc_e1", toolInput: "{}", toolResponse: readResult))
        let sid = try #require(reply.sessionId)
        let user = env.home.appendingPathComponent("claude-user-settings.json")
        DioramaDaemon.endDisconnectedHookSessions(store: env.daemon.store, userSettings: user, userPlugin: noUserPlugin)
        #expect(try await env.client.session(sid).status == .active)
        try HookInstaller.uninstall(settings: plugin)
        DioramaDaemon.endDisconnectedHookSessions(store: env.daemon.store, userSettings: user, userPlugin: noUserPlugin)
        #expect(try await env.client.session(sid).status == .ended)
    }
}
