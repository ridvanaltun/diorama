import DioramaCore
import DioramaJSON
import DioramaStore
import Foundation
import Testing
@testable import DioramaEngine

@Suite struct RuleMismatchTests {
    func ctx(tool: String = "WebFetch", input: String = #"{"url":"https://docs.example.com/v1"}"#, text: String = "Version 1 is current", error: Bool = false, stage: RuleStage = .result) throws -> MatchContext {
        MatchContext(toolName: tool, toolInput: try JSONValue.parse(input), text: text, requestClass: "main", isError: error, stage: stage)
    }

    @Test func explainsTheFirstFailingCondition() throws {
        var r = Rule(name: "r", match: RuleMatch(tools: ["WebFetch"]), instructions: "x")
        #expect(RuleMatcher.mismatch(r, try ctx()) == nil)
        #expect(RuleMatcher.mismatch(r, try ctx(tool: "Read")) == "Read isn't in the rule's tools (WebFetch)")
        #expect(RuleMatcher.mismatch(r, try ctx(error: true)) == "the result is an error and the rule excludes errors")
        #expect(RuleMatcher.mismatch(r, try ctx(stage: .page))?.contains("applies to tool results") == true)
        r.match.input = ["url": "example\\.org"]
        #expect(RuleMatcher.mismatch(r, try ctx()) == "input “url” (https://docs.example.com/v1) doesn't match /example\\.org/")
        r.match.input = ["query": "x"]
        #expect(RuleMatcher.mismatch(r, try ctx()) == "the tool input has no “query” field")
        r.match.input = [:]
        r.match.content = "deprecated"
        #expect(RuleMatcher.mismatch(r, try ctx()) == "the content doesn't match /deprecated/")
        r.match.content = "("
        #expect(RuleMatcher.mismatch(r, try ctx()) == "the content regex isn't valid")
        r.match.content = nil
        r.enabled = false
        #expect(RuleMatcher.mismatch(r, try ctx()) == "the rule is disabled")
        #expect(!RuleMatcher.matches(r, try ctx()))
    }
}

@Suite struct PlaygroundEngineTests {
    let rules = [
        Rule(id: "a", name: "Docs", match: RuleMatch(tools: ["WebFetch"], input: ["url": "docs\\."]), instructions: "Say version 2 replaced it"),
        Rule(id: "b", name: "Shell", match: RuleMatch(tools: ["Bash"]), instructions: "x"),
    ]

    @Test func checksForFreeAndRewritesWithoutRecording() async throws {
        let store = try tempStore()
        let counter = CallCounter()
        let engine = DecisionEngine(store: store) { countingProvider(counter, .replacing("Version 1", with: "Version 2")) }
        let check = await engine.playground(rules: rules, defaults: ProfileDefaults(), toolName: "WebFetch", toolInputJSON: #"{"url":"https://docs.example.com"}"#,
                                            segments: ["Version 1 is current"], stage: .result, rewrite: false)
        #expect(check.checks.map(\.matches) == [true, false])
        #expect(check.checks[1].reason == "WebFetch isn't in the rule's tools (Bash)")
        #expect(check.model == ProfileDefaults.defaultModel)
        #expect(check.rewrite == nil)
        #expect(counter.count == 0)

        let done = await engine.playground(rules: rules, defaults: ProfileDefaults(), toolName: "WebFetch", toolInputJSON: #"{"url":"https://docs.example.com"}"#,
                                           segments: ["Version 1 is current"], stage: .result, rewrite: true)
        #expect(done.rewrite?.status == .succeeded)
        #expect(done.rewrite?.replacementText == "Version 2 is current")
        #expect(counter.count == 1)
        #expect(try store.recentDecisions().isEmpty, "the playground must not record decisions")

        let none = await engine.playground(rules: rules, defaults: ProfileDefaults(), toolName: "Read", toolInputJSON: nil,
                                           segments: ["Version 1"], stage: .result, rewrite: true)
        #expect(none.model == nil && none.rewrite == nil)
        #expect(none.note?.contains("No rule matches") == true)
        #expect(counter.count == 1)
    }
}
