import DioramaClient
import DioramaCore
import DioramaEngine
import Foundation
import Testing
@testable import DioramaGateway

@Suite struct InputHookTests {
    let rules = [Rule(name: "Redirect", match: RuleMatch(tools: ["WebFetch"], stage: .input), instructions: "rename")]

    @Test func hookModeAndGatewaySessionsGetChangedInputs() async throws {
        let env = try await TestEnv.start(provider: ScriptedRewriteProvider.replacing("example.com", with: "example.org"), cliPath: "/Apps/Diorama.app/Contents/Helpers/diorama")
        defer { Task { await env.stop() } }
        _ = try await env.client.createProfile(Profile(name: "redirect", rules: rules))
        let input = #"{"url":"https://example.com","prompt":"p"}"#

        // Hook mode (installed hook): PreToolUse returns the new input.
        let r = try await env.client.hook(HookEvent(event: "PreToolUse", claudeSessionId: "c-in", cwd: "/tmp/x", toolName: "WebFetch", toolUseId: "toolu_h", toolInput: input, config: HookConfig(profile: "redirect")))
        #expect(r.outcome == .rewritten)
        #expect(r.updatedInput?.contains("example.org") == true)
        #expect(r.updatedToolOutput == nil)

        // `diorama run`: the session's settings add a PreToolUse hook, which reports with the gateway session id.
        let launch = try await env.client.createSession(SessionSpec(name: "g", cwd: "/tmp", profile: "redirect"))
        let settings = try #require(launch.claudeArguments.last)
        #expect(settings.contains("PreToolUse") && settings.contains("'/Apps/Diorama.app/Contents/Helpers/diorama' hook run"))
        let g = try await env.client.hook(HookEvent(event: "PreToolUse", claudeSessionId: "c-gw", cwd: "/tmp", toolName: "WebFetch", toolUseId: "toolu_g",
                                                    toolInput: input, dioramaSessionId: launch.session.id))
        #expect(g.sessionId == launch.session.id && g.updatedInput?.contains("example.org") == true)
        #expect(try await env.client.timeline(launch.session.id).decisions.map(\.toolUseId) == ["input:toolu_g"])
        // …and nothing else from that hook.
        #expect(try await env.client.hook(HookEvent(event: "PostToolUse", claudeSessionId: "c-gw", cwd: "/tmp", toolName: "WebFetch", toolUseId: "toolu_g2",
                                                    toolInput: input, toolResponse: "{}", dioramaSessionId: launch.session.id)).sessionId == nil)

        // Trials never get the hook (nobody could approve the calls); sessions without input rules don't either.
        let trial = try await env.client.createSession(SessionSpec(name: "t", cwd: "/tmp", profile: "redirect", kind: .trial))
        #expect(!(trial.claudeArguments.last ?? "").contains("PreToolUse"))
        let plain = try await env.client.createSession(SessionSpec(name: "p", cwd: "/tmp"))
        #expect(!(plain.claudeArguments.last ?? "").contains("PreToolUse"))
    }
}
