import DioramaClient
@testable import DioramaCore
import Foundation
import Testing

@Suite struct DataExportTests {
    @Test func exportsFilteredDecisions() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        _ = try await env.client.createProfile(Profile(name: "web", rules: [Rule(name: "Rename", match: RuleMatch(tools: ["WebFetch"]), instructions: "rename")]))
        let s = try await env.client.createSession(SessionSpec(name: "export me", cwd: "/tmp", profile: "web"))
        _ = try await env.post(s.token, body: sampleBody(results: [("toolu_e1", "Example Domain page"), ("toolu_e2", "plain page")]))
        let plain = try await env.client.createSession(SessionSpec(name: "no profile", cwd: "/tmp"))
        _ = try await env.post(plain.token, body: sampleBody(results: [("toolu_e3", "Example Domain")]))
        let trial = try await env.client.createSession(SessionSpec(name: "t", cwd: "/tmp", profile: "web", kind: .trial, trialId: "tri_e"))
        _ = try await env.post(trial.token, body: sampleBody(results: [("toolu_e4", "Example Domain trial")]))

        let all = try await env.client.exportDecisions(format: .jsonl)
        #expect(all.rows == 4)
        let rows = try all.content.split(separator: "\n").map { try DioramaCoding.decoder.decode(DecisionExportRow.self, from: Data($0.utf8)) }
        let e1 = try #require(rows.first { $0.decisionId == "toolu_e1" })
        #expect(e1.sessionName == "export me" && e1.profile == "web" && e1.profileVersion == 1 && e1.tool == "WebFetch" && e1.stage == "result")
        #expect(e1.outcome == "rewritten" && e1.rules == ["Rename"] && e1.attempts == 1 && e1.originalChars == 19 && e1.replacementChars == 22)
        #expect(e1.originalText == nil, "texts are opt-in")
        #expect(rows.first { $0.decisionId == "toolu_e4" }?.trialId == "tri_e")

        let web = try await env.client.exportDecisions(format: .jsonl, profile: "web", includeTrials: false, rewrittenOnly: true, includeTexts: true)
        #expect(web.rows == 1 && web.content.contains(#""replacementText":"Morph Test Domain page""#))
        let csv = try await env.client.exportDecisions(sessionId: s.session.id)
        let lines = csv.content.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        #expect(csv.rows == 2 && lines.count == 3 && lines[0].hasPrefix("decision_id,created_at,session_id"))
        await #expect(throws: (any Error).self) { try await env.client.exportDecisions(profile: "missing") }
    }

    @Test func csvQuotesAndDefusesFormulas() {
        #expect(DataExport.csvCell("plain") == "plain")
        #expect(DataExport.csvCell("a,b") == "\"a,b\"")
        #expect(DataExport.csvCell("say \"hi\"\nok") == "\"say \"\"hi\"\"\nok\"")
        #expect(DataExport.csvCell("=HYPERLINK(\"x\")") == "\"'=HYPERLINK(\"\"x\"\")\"")
        #expect(DataExport.csvCell("-1.5") == "-1.5")
        let row = DecisionExportRow(decisionId: "t", createdAt: Date(timeIntervalSince1970: 0), sessionId: "s", sessionName: "n", sessionKind: "interactive",
                                    via: "gateway", trialId: nil, profile: nil, profileVersion: nil, tool: "Bash", stage: "result", toolInput: #"{"command":"ls"}"#,
                                    isError: false, outcome: "unchanged", reason: "no rule matched", rules: [], attempts: 0, costUSD: 0, originalChars: 3,
                                    replacementChars: nil, originalText: "abc")
        let csv = DataExport.render([row], format: .csv, includeTexts: true)
        #expect(csv.hasSuffix(#"t,1970-01-01T00:00:00.000Z,s,n,interactive,gateway,,,,Bash,result,"{""command"":""ls""}",false,unchanged,no rule matched,,0,0.000000,3,,abc,"# + "\r\n"))
        #expect(DataExport.render([], format: .jsonl, includeTexts: false) == "")
    }
}
