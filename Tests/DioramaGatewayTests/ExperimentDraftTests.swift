import DioramaClient
import DioramaCore
import Foundation
import Testing
@testable import DioramaGateway

@Suite struct ExperimentDraftTests {
    @Test func draftsFromAGatewaySessionPinnedToItsVersion() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        let v1 = try await env.client.createProfile(Profile(name: "web steer", rules: [Rule(name: "Rename", match: RuleMatch(tools: ["WebFetch"]), instructions: "rename")]))
        let launch = try await env.client.createSession(SessionSpec(name: "docs check", cwd: "/tmp", profile: "web steer"))
        _ = try await env.post(launch.token, body: sampleBody())
        _ = try await env.client.updateProfile("web steer", Profile(name: "web steer", rules: [Rule(name: "Rename v2", match: RuleMatch(tools: ["WebFetch"]), instructions: "x")]))

        let draft = try await env.client.experimentDraft(sessionId: launch.session.id, trials: 4)
        let d = draft.definition
        #expect(d.task == "fetch it")
        #expect(d.projectPath == "/tmp")
        #expect(d.name == "docs check — experiment")
        #expect(d.claude.allowedTools == ["WebFetch"])
        #expect(d.claude.model == "claude-opus-5-5")
        #expect(d.claude.isolateConfiguration)
        #expect(d.trialsPerVariant == 4)
        #expect(d.variants.map(\.key) == ["control", "steered"])
        #expect(d.variants[0].isControl)
        #expect(d.variants[1].profile == v1.id, "pinned to the version the session used")
        #expect(d.variants[1].name == "web steer v1")
        #expect(draft.notes.contains { $0.contains("Pinned to v1") && $0.contains("current one is v2") })

        // The draft is a valid definition: pinned versions resolve.
        let e = try await env.client.createExperiment(d)
        #expect(e.definition.variants[1].profile == v1.id)
    }

    @Test func draftsFromAHookSessionAndExplainsGaps() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        let transcript = FileManager.default.temporaryDirectory.appendingPathComponent("diorama-transcript-\(UUID().uuidString).jsonl")
        try """
            {"type":"summary","summary":"x"}
            {"type":"user","message":{"role":"user","content":"Summarize the API docs for v2"}}
            """.write(to: transcript, atomically: true, encoding: .utf8)
        let prompt = SessionPrompt(text: "Say v1 is deprecated", tools: ["WebFetch"])
        _ = try await env.client.hook(HookEvent(event: "SessionStart", claudeSessionId: "c-draft", cwd: "/tmp/app", transcriptPath: transcript.path, config: HookConfig(prompt: prompt)))
        let reply = try await env.client.hook(HookEvent(event: "PostToolUse", claudeSessionId: "c-draft", cwd: "/tmp/app", toolName: "WebFetch", toolUseId: "toolu_d1",
                                                        toolInput: #"{"url":"https://example.com"}"#, toolResponse: #"{"result":"Example Domain"}"#, config: HookConfig(prompt: prompt)))
        let draft = try await env.client.experimentDraft(sessionId: try #require(reply.sessionId))
        #expect(draft.definition.task == "Summarize the API docs for v2")
        #expect(draft.definition.claude.model == nil)
        #expect(draft.definition.variants[1].prompt?.text == "Say v1 is deprecated")
        #expect(draft.definition.variants[1].name == "Session prompt")

        // A record-only session has nothing to compare; a trial can't be drafted from.
        let plain = try await env.client.createSession(SessionSpec(name: "plain", cwd: "/tmp"))
        let empty = try await env.client.experimentDraft(sessionId: plain.session.id)
        #expect(empty.notes.contains { $0.contains("no profile or prompt") })
        #expect(empty.notes.contains { $0.contains("first prompt wasn't recorded") })
        let trial = try await env.client.createSession(SessionSpec(name: "t", cwd: "/tmp", kind: .trial))
        await #expect(throws: ClientError.self) { _ = try await env.client.experimentDraft(sessionId: trial.session.id) }
    }
}
