import DioramaCore
import DioramaJSON
import DioramaStore
import Foundation
import Testing
@testable import DioramaEngine

@Suite struct InputRewriteTests {
    func inputSession(_ store: Store) throws -> SessionRecord {
        let p = try store.createProfile(Profile(name: "redirect-\(UUID().uuidString.prefix(6))", rules: [
            Rule(name: "Redirect docs", match: RuleMatch(tools: ["WebFetch"], stage: .input), instructions: "Point example.com at example.org"),
            Rule(name: "Results", match: RuleMatch(tools: ["WebFetch"]), instructions: "never used for inputs"),
        ]))
        return try store.createSession(SessionSpec(name: "i", cwd: "/tmp", profile: p.profileId, via: .hook), tokenHash: "hook:" + Hashing.randomToken())
    }

    @Test func changesValuesKeepsKeysAndFreezes() async throws {
        let store = try tempStore()
        let counter = CallCounter()
        let engine = DecisionEngine(store: store) { countingProvider(counter, .replacing("example.com", with: "example.org")) }
        let s = try inputSession(store)
        let input = #"{"url":"https://example.com/docs","prompt":"What is the heading?"}"#
        let (d, out) = await engine.decideInput(session: s, toolUseId: "toolu_in1", toolName: "WebFetch", toolInputJSON: input, taskText: nil)
        #expect(d?.toolUseId == "input:toolu_in1")
        #expect(d?.outcome == .rewritten)
        let new = try JSONValue.parse(try #require(out))
        #expect(new["url"]?.stringValue == "https://example.org/docs")
        #expect(new["prompt"]?.stringValue == "What is the heading?")
        #expect(counter.all.first?.toolName.contains("TOOL INPUT") == true)
        #expect(counter.all.first?.instructions.map(\.name) == ["Redirect docs"], "result rules don't apply to inputs")

        let (again, out2) = await engine.decideInput(session: s, toolUseId: "toolu_in1", toolName: "WebFetch", toolInputJSON: input, taskText: nil)
        #expect(again?.outcome == .rewritten && out2 == out && counter.count == 1)
    }

    @Test func rejectsNewParametersAfterOneRetry() async throws {
        let store = try tempStore()
        let counter = CallCounter()
        // Replaces the whole input with one that adds a key.
        let adds = ScriptedRewriteProvider { req in
            counter.record(req)
            return RewriteResponse(status: .succeeded, output: RewriteOutput(decision: .replace, content: #"{"url":"https://evil.example","prompt":"p","extra":true}"#, explanation: "x"), modelServed: "scripted")
        }
        let engine = DecisionEngine(store: store) { adds }
        let s = try inputSession(store)
        let (d, out) = await engine.decideInput(session: s, toolUseId: "toolu_in2", toolName: "WebFetch", toolInputJSON: #"{"url":"https://example.com","prompt":"p"}"#, taskText: nil)
        #expect(out == nil)
        #expect(d?.outcome == .failed)
        #expect(d?.reason.contains("same keys") == true)
        #expect(counter.count == 2, "one retry with the problem as feedback")
        #expect(counter.all.last?.feedback?.contains("same keys") == true)
    }

    @Test func callsNoInputRuleMatchesLeaveNoRecord() async throws {
        let store = try tempStore()
        let counter = CallCounter()
        let engine = DecisionEngine(store: store) { countingProvider(counter, .replacing("x", with: "y")) }
        let s = try inputSession(store)
        let (d, out) = await engine.decideInput(session: s, toolUseId: "toolu_in3", toolName: "Bash", toolInputJSON: #"{"command":"ls"}"#, taskText: nil)
        #expect(d == nil && out == nil)
        #expect(try store.decision(toolUseId: "input:toolu_in3") == nil)
        #expect(counter.count == 0)
    }
}
