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
        #expect(cmd1 == "'/Apps/Diorama.app/Contents/Helpers/diorama' hook run --profile 'Docs steer'")
        try HookInstaller.install(command: cmd1, settings: url)
        var root = try load(url)
        var hooks = try #require(root["hooks"] as? [String: Any])
        #expect((hooks["PostToolUse"] as? [[String: Any]])?.count == 2)
        #expect((hooks["SessionStart"] as? [[String: Any]])?.count == 1)
        #expect((hooks["SessionEnd"] as? [[String: Any]])?.count == 1)
        #expect(HookInstaller.installedCommand(settings: url) == cmd1)

        // Installing again replaces Diorama's entries instead of adding more.
        let cmd2 = try HookInstaller.command(cli: "/x/diorama", config: HookConfig(prompt: SessionPrompt(text: "it's new", tools: ["WebFetch"], context: .task)))
        #expect(cmd2 == "'/x/diorama' hook run --prompt 'it'\\''s new' --prompt-tools 'WebFetch' --prompt-context task")
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
}
