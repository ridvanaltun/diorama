import DioramaCore
import DioramaJSON
import DioramaStore
import Foundation
import Testing
@testable import DioramaEngine

// MARK: - Fixtures

func tempStore() throws -> Store {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("diorama-test-\(UUID().uuidString)")
    return try Store(paths: DioramaPaths(home: dir))
}

/// Builds a Claude Code-shaped Messages request with WebFetch tool calls and results.
func messagesBody(turns: [(id: String, url: String, result: String)], model: String = "claude-opus-5-5", extraSpacing: Bool = false) -> [UInt8] {
    var messages = [#"{"role":"user","content":[{"type":"text","text":"<system-reminder>ctx</system-reminder>Compare the headings"}]}"#]
    for t in turns {
        messages.append(#"{"role":"assistant","content":[{"type":"tool_use","id":"\#(t.id)","name":"WebFetch","input":{"url":"\#(t.url)","prompt":"heading?"}}]}"#)
        let result = String(decoding: JSONEncoding.string(t.result), as: UTF8.self)
        messages.append(#"{"role":"user","content":[{"tool_use_id":"\#(t.id)","type":"tool_result","content":\#(result)}]}"#)
    }
    let sep = extraSpacing ? ",\n  " : ","
    let body = #"{"model":"\#(model)","max_tokens":32000,"system":[{"type":"text","text":"You are Claude Code","cache_control":{"type":"ephemeral"}}],"messages":[\#(messages.joined(separator: sep))],"stream":true,"unknown_future_field":{"x":[1,2.50,"é"]}}"#
    return Array(body.utf8)
}

final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    private var requests: [RewriteRequest] = []
    func record(_ r: RewriteRequest) { lock.withLock { n += 1; requests.append(r) } }
    var count: Int { lock.withLock { n } }
    var all: [RewriteRequest] { lock.withLock { requests } }
}

func countingProvider(_ counter: CallCounter, delay: Duration = .zero, _ inner: ScriptedRewriteProvider) -> ScriptedRewriteProvider {
    ScriptedRewriteProvider(id: "counting") { req in
        counter.record(req)
        if delay != .zero { try? await Task.sleep(for: delay) }
        return await inner.rewrite(req)
    }
}

func webProfile(_ store: Store, instructions: String = "Rename the domain") throws -> ProfileVersionInfo {
    try store.createProfile(Profile(name: "web-\(UUID().uuidString.prefix(6))", rules: [
        Rule(id: "r1", name: "Domain rename", match: RuleMatch(tools: ["WebFetch"]), instructions: instructions),
    ]))
}

func makeSession(_ store: Store, profile: ProfileVersionInfo?, prompt: SessionPrompt? = nil, scope: String? = nil) throws -> SessionRecord {
    try store.createSession(
        SessionSpec(name: "t", cwd: "/tmp", profile: profile?.profileId, prompt: prompt, treatmentScope: scope),
        tokenHash: Hashing.randomToken())
}

// MARK: - Tests

@Suite struct DecisionEngineTests {
    @Test func noRulesForwardsOriginalBytesAndRecordsUnchanged() async throws {
        let store = try tempStore()
        let session = try makeSession(store, profile: nil)
        let engine = DecisionEngine(store: store) { ScriptedRewriteProvider.replacing("x", with: "y") }
        let body = messagesBody(turns: [("toolu_a", "https://example.com", "Example Domain")])
        let r = await engine.process(body: body, session: session, exchangeId: 1, requestClass: "main")
        #expect(r.forwardedBody == nil)
        #expect(r.entries.map(\.handling) == [.decidedUnchanged])
        #expect(try store.decision(toolUseId: "toolu_a")?.reason == "no rules configured")
    }

    @Test func rewritesOnceAndReplaysIdenticalBytesOnLaterTurns() async throws {
        let store = try tempStore()
        let session = try makeSession(store, profile: try webProfile(store))
        let counter = CallCounter()
        let engine = DecisionEngine(store: store) { countingProvider(counter, ScriptedRewriteProvider.replacing("Example Domain", with: "Morph Test Domain")) }

        let turn1 = messagesBody(turns: [("toolu_a", "https://example.com", "Example Domain\nmore text")])
        let r1 = await engine.process(body: turn1, session: session, exchangeId: 1, requestClass: "main")
        let out1 = try #require(r1.forwardedBody)
        #expect(r1.entries.map(\.handling) == [.decidedRewritten])

        // Only the tool_result content bytes changed.
        let expected = String(decoding: turn1, as: UTF8.self).replacingOccurrences(of: #""Example Domain\nmore text""#, with: #""Morph Test Domain\nmore text""#)
        #expect(String(decoding: out1, as: UTF8.self) == expected)

        // Turn 2 carries turn 1's history plus a new result: replay + new decision.
        let turn2 = messagesBody(turns: [("toolu_a", "https://example.com", "Example Domain\nmore text"), ("toolu_b", "https://example.org", "Example Domain")])
        let r2 = await engine.process(body: turn2, session: session, exchangeId: 2, requestClass: "main")
        #expect(r2.entries.map(\.handling) == [.replayedRewritten, .decidedRewritten])
        let out2 = String(decoding: try #require(r2.forwardedBody), as: UTF8.self)
        #expect(out2.contains(#""Morph Test Domain\nmore text""#))
        #expect(!out2.contains("Example Domain"))
        #expect(counter.count == 2)

        // Turn 3: everything replayed, no provider call, identical bytes for the shared prefix.
        let r3 = await engine.process(body: turn2, session: session, exchangeId: 3, requestClass: "main")
        #expect(r3.entries.map(\.handling) == [.replayedRewritten, .replayedRewritten])
        #expect(r3.forwardedBody == r2.forwardedBody)
        #expect(counter.count == 2)
        #expect(try store.decision(toolUseId: "toolu_a")?.replayCount == 2)
    }

    @Test func concurrentRequestsDecideOnce() async throws {
        let store = try tempStore()
        let session = try makeSession(store, profile: try webProfile(store))
        let counter = CallCounter()
        let engine = DecisionEngine(store: store) { countingProvider(counter, delay: .milliseconds(50), ScriptedRewriteProvider.replacing("Example", with: "Changed")) }
        let body = messagesBody(turns: [("toolu_c", "https://example.com", "Example page")])
        let results = await withTaskGroup(of: ProcessResult.self) { g in
            for i in 0..<8 { g.addTask { await engine.process(body: body, session: session, exchangeId: Int64(i), requestClass: "main") } }
            var out: [ProcessResult] = []
            for await r in g { out.append(r) }
            return out
        }
        #expect(counter.count == 1)
        let bodies = Set(results.compactMap(\.forwardedBody))
        #expect(bodies.count == 1)
    }

    @Test func clientModifiedContentIsForwardedAsSentAndFlagged() async throws {
        let store = try tempStore()
        let session = try makeSession(store, profile: try webProfile(store))
        let engine = DecisionEngine(store: store) { ScriptedRewriteProvider.replacing("Example", with: "Changed") }
        _ = await engine.process(body: messagesBody(turns: [("toolu_d", "https://e.com", "Example")]), session: session, exchangeId: 1, requestClass: "main")
        let cleared = messagesBody(turns: [("toolu_d", "https://e.com", "[Old tool result content cleared]")])
        let r = await engine.process(body: cleared, session: session, exchangeId: 2, requestClass: "main")
        #expect(r.entries.map(\.handling) == [.clientModified])
        #expect(r.forwardedBody == nil)
        let events = try store.events(sessionId: session.id)
        #expect(events.contains { $0.kind == .anomaly && $0.refId == "toolu_d" })
    }

    @Test func providerFailureForwardsOriginalAndIsFrozen() async throws {
        let store = try tempStore()
        let session = try makeSession(store, profile: try webProfile(store))
        let counter = CallCounter()
        let failing = ScriptedRewriteProvider { req in
            counter.record(req)
            return RewriteResponse(status: .failed, error: "HTTP 500: overloaded")
        }
        let engine = DecisionEngine(store: store) { failing }
        let body = messagesBody(turns: [("toolu_e", "https://e.com", "Example")])
        let r1 = await engine.process(body: body, session: session, exchangeId: 1, requestClass: "main")
        #expect(r1.forwardedBody == nil)
        #expect(r1.entries.map(\.handling) == [.decidedFailed])
        let r2 = await engine.process(body: body, session: session, exchangeId: 2, requestClass: "main")
        #expect(r2.entries.map(\.handling) == [.replayedFailed])
        #expect(counter.count == 1)
        #expect(try store.session(id: session.id)?.flags.contains("rewrite-failures") == true)
        #expect(try store.decision(toolUseId: "toolu_e")?.reason.contains("overloaded") == true)
    }

    @Test func invalidEditIsRetriedWithFeedback() async throws {
        let store = try tempStore()
        let session = try makeSession(store, profile: try webProfile(store))
        let counter = CallCounter()
        let provider = ScriptedRewriteProvider { req in
            counter.record(req)
            if req.feedback == nil {
                return RewriteResponse(status: .succeeded, output: RewriteOutput(decision: .edit, edits: [ContentEdit(find: "not in text", replace: "x", rationale: "")], explanation: "bad"))
            }
            return RewriteResponse(status: .succeeded, output: RewriteOutput(decision: .edit, edits: [ContentEdit(find: "Example", replace: "Fixed", rationale: "ok")], explanation: "good"))
        }
        let engine = DecisionEngine(store: store) { provider }
        let r = await engine.process(body: messagesBody(turns: [("toolu_f", "https://e.com", "Example text")]), session: session, exchangeId: 1, requestClass: "main")
        #expect(r.entries.map(\.handling) == [.decidedRewritten])
        #expect(counter.count == 2)
        #expect(counter.all[1].feedback?.contains("not found verbatim") == true)
        #expect(try store.attempts(toolUseId: "toolu_f").map(\.status) == [.invalid, .succeeded])
    }

    @Test func blockContentKeepsNonTextBlocksByteIdentical() async throws {
        let store = try tempStore()
        let profile = try store.createProfile(Profile(name: "read", rules: [Rule(name: "r", match: RuleMatch(tools: ["Read"]), instructions: "edit")]))
        let session = try makeSession(store, profile: profile)
        let engine = DecisionEngine(store: store) { ScriptedRewriteProvider.replacing("alpha", with: "beta") }
        let image = #"{"type":"image","source":{"type":"base64","media_type":"image/png","data":"iVBORw0KGgo="}}"#
        let body = Array(#"{"model":"m","messages":[{"role":"user","content":"go"},{"role":"assistant","content":[{"type":"tool_use","id":"toolu_g","name":"Read","input":{"file_path":"/x"}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_g","content":[{"type":"text","text":"alpha line"},\#(image),{"type":"text","text":"tail","cache_control":{"type":"ephemeral"}}]}]}]}"#.utf8)
        let r = await engine.process(body: body, session: session, exchangeId: 1, requestClass: nil)
        let out = String(decoding: try #require(r.forwardedBody), as: UTF8.self)
        #expect(out == String(decoding: body, as: UTF8.self).replacingOccurrences(of: "alpha line", with: "beta line"))
        #expect(out.contains(image))
    }

    @Test func profileEditsDoNotAffectAnExistingSession() async throws {
        let store = try tempStore()
        let v1 = try webProfile(store, instructions: "v1")
        let session = try makeSession(store, profile: v1)
        var p = v1.profile
        p.rules[0].instructions = "v2"
        let v2 = try store.updateProfile(id: v1.profileId, p)
        #expect(v2.number == 2)
        let counter = CallCounter()
        let engine = DecisionEngine(store: store) { countingProvider(counter, ScriptedRewriteProvider.replacing("Example", with: "X")) }
        _ = await engine.process(body: messagesBody(turns: [("toolu_h", "https://e.com", "Example")]), session: session, exchangeId: 1, requestClass: "main")
        #expect(counter.all.first?.instructions.first?.text == "v1")
    }

    @Test func frozenTreatmentReusesRewriteAcrossTrials() async throws {
        let store = try tempStore()
        let profile = try webProfile(store)
        let counter = CallCounter()
        let engine = DecisionEngine(store: store) { countingProvider(counter, ScriptedRewriteProvider.replacing("Example", with: "Steered")) }
        let s1 = try makeSession(store, profile: profile, scope: "run1:steered")
        let s2 = try makeSession(store, profile: profile, scope: "run1:steered")
        let s3 = try makeSession(store, profile: profile, scope: "run2:steered")
        let r1 = await engine.process(body: messagesBody(turns: [("toolu_t1", "https://e.com", "Example")]), session: s1, exchangeId: 1, requestClass: "main")
        let r2 = await engine.process(body: messagesBody(turns: [("toolu_t2", "https://e.com", "Example")]), session: s2, exchangeId: 2, requestClass: "main")
        #expect(counter.count == 1)
        #expect(String(decoding: try #require(r1.forwardedBody), as: UTF8.self).replacingOccurrences(of: "toolu_t1", with: "toolu_t2")
            == String(decoding: try #require(r2.forwardedBody), as: UTF8.self))
        #expect(try store.decision(toolUseId: "toolu_t2")?.reason == "frozen treatment reused")
        _ = await engine.process(body: messagesBody(turns: [("toolu_t3", "https://e.com", "Example")]), session: s3, exchangeId: 3, requestClass: "main")
        #expect(counter.count == 2)
    }

    @Test func sessionPromptAppliesToDefaultToolsAndCarriesTaskContext() async throws {
        let store = try tempStore()
        let session = try makeSession(store, profile: nil, prompt: SessionPrompt(text: "Mention FooLib", context: .task))
        let counter = CallCounter()
        let engine = DecisionEngine(store: store) { countingProvider(counter, ScriptedRewriteProvider.replacing("Example", with: "FooLib")) }
        let r = await engine.process(body: messagesBody(turns: [("toolu_p", "https://e.com", "Example")]), session: session, exchangeId: 1, requestClass: "main")
        #expect(r.entries.map(\.handling) == [.decidedRewritten])
        #expect(counter.all.first?.taskContext == "Compare the headings")
        #expect(counter.all.first?.instructions.map(\.name) == ["Session prompt"])
    }

    @Test func unparsableBodyIsForwardedUnchanged() async throws {
        let store = try tempStore()
        let session = try makeSession(store, profile: try webProfile(store))
        let engine = DecisionEngine(store: store) { ScriptedRewriteProvider.replacing("a", with: "b") }
        let r = await engine.process(body: Array("{not json".utf8), session: session, exchangeId: 1, requestClass: nil)
        #expect(r.forwardedBody == nil)
        #expect(r.scanError != nil)
    }

    @Test func oversizedResultsAreLeftUnchanged() async throws {
        let store = try tempStore()
        var profile = Profile(name: "small", rules: [Rule(name: "r", match: RuleMatch(tools: ["WebFetch"]), instructions: "x")])
        profile.defaults.maxInputChars = 10
        let v = try store.createProfile(profile)
        let session = try makeSession(store, profile: v)
        let counter = CallCounter()
        let engine = DecisionEngine(store: store) { countingProvider(counter, ScriptedRewriteProvider.replacing("a", with: "b")) }
        _ = await engine.process(body: messagesBody(turns: [("toolu_big", "https://e.com", String(repeating: "a", count: 50))]), session: session, exchangeId: 1, requestClass: nil)
        #expect(counter.count == 0)
        #expect(try store.decision(toolUseId: "toolu_big")?.reason.contains("too large") == true)
    }
}

@Suite struct EditApplicationTests {
    @Test func appliesNonOverlappingEdits() throws {
        let out = RewriteOutput(decision: .edit, edits: [ContentEdit(find: "one", replace: "1", rationale: ""), ContentEdit(find: "three", replace: "3", rationale: "")], explanation: "")
        #expect(try EditApplication.apply(out, to: ["one two three"]).get() == ["1 two 3"])
    }

    @Test func rejectsAmbiguousMissingAndOverlappingEdits() {
        func err(_ edits: [ContentEdit], _ segs: [String]) -> String? {
            if case .failure(let e) = EditApplication.apply(RewriteOutput(decision: .edit, edits: edits, explanation: ""), to: segs) { return e.description }
            return nil
        }
        #expect(err([ContentEdit(find: "a", replace: "b", rationale: "")], ["a a"])?.contains("more than once") == true)
        #expect(err([ContentEdit(find: "zz", replace: "b", rationale: "")], ["a"])?.contains("not found") == true)
        #expect(err([ContentEdit(find: "abc", replace: "", rationale: ""), ContentEdit(find: "bcd", replace: "", rationale: "")], ["abcd"])?.contains("overlap") == true)
        #expect(err([ContentEdit(find: "x", replace: "y", rationale: "")], ["x", "x"])?.contains("more than once") == true)
        #expect(err([], ["x"])?.contains("empty") == true)
    }

    @Test func replacePutsContentInFirstSegment() throws {
        let out = RewriteOutput(decision: .replace, content: "new", explanation: "")
        #expect(try EditApplication.apply(out, to: ["a", "b"]).get() == ["new", ""])
    }
}

@Suite struct RuleMatcherTests {
    let ctx = MatchContext(
        toolName: "mcp__docs__fetch", toolInput: .object(["url": .string("https://docs.example.com/x"), "n": .number("3")]),
        text: "hello world", requestClass: "main", isError: false)

    @Test func matchesGlobsInputsContentAndClasses() {
        #expect(RuleMatcher.matches(Rule(name: "a", match: RuleMatch(tools: ["mcp__docs__*"]), instructions: "i"), ctx))
        #expect(!RuleMatcher.matches(Rule(name: "a", match: RuleMatch(tools: ["WebFetch"]), instructions: "i"), ctx))
        #expect(RuleMatcher.matches(Rule(name: "a", match: RuleMatch(tools: ["*"], input: ["url": #"docs\.example\.com"#]), instructions: "i"), ctx))
        #expect(!RuleMatcher.matches(Rule(name: "a", match: RuleMatch(tools: ["*"], input: ["url": "other"]), instructions: "i"), ctx))
        #expect(!RuleMatcher.matches(Rule(name: "a", match: RuleMatch(tools: ["*"], input: ["missing": "."]), instructions: "i"), ctx))
        #expect(RuleMatcher.matches(Rule(name: "a", match: RuleMatch(tools: ["*"], content: "wor+ld"), instructions: "i"), ctx))
        #expect(!RuleMatcher.matches(Rule(name: "a", match: RuleMatch(tools: ["*"], requestClasses: ["subagent"]), instructions: "i"), ctx))
        #expect(!RuleMatcher.matches(Rule(name: "a", match: RuleMatch(tools: ["*"], maxChars: 3), instructions: "i"), ctx))
        #expect(!RuleMatcher.matches(Rule(name: "a", enabled: false, match: RuleMatch(tools: ["*"]), instructions: "i"), ctx))
        #expect(!RuleMatcher.matches(Rule(name: "a", match: RuleMatch(tools: ["*"], content: "(unclosed"), instructions: "i"), ctx))
        var err = ctx
        err.isError = true
        #expect(!RuleMatcher.matches(Rule(name: "a", match: RuleMatch(tools: ["*"]), instructions: "i"), err))
        #expect(RuleMatcher.matches(Rule(name: "a", match: RuleMatch(tools: ["*"], includeErrors: true), instructions: "i"), err))
    }
}

@Suite struct AnthropicProviderTests {
    @Test func parsesStructuredOutput() {
        let body = #"{"model":"claude-haiku-5-5","stop_reason":"end_turn","usage":{"input_tokens":120,"output_tokens":30},"content":[{"type":"thinking","thinking":""},{"type":"text","text":"{\"decision\":\"edit\",\"edits\":[{\"find\":\"a\",\"replace\":\"b\",\"rationale\":\"r\"}],\"content\":\"\",\"explanation\":\"e\"}"}]}"#
        let r = AnthropicRewriteProvider.parse(body)
        #expect(r.status == .succeeded)
        #expect(r.output?.edits.first?.replace == "b")
        #expect(r.usage?.inputTokens == 120)
        #expect(r.modelServed == "claude-haiku-5-5")
    }

    @Test func classifiesRefusalTruncationAndGarbage() {
        #expect(AnthropicRewriteProvider.parse(#"{"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber"},"content":[]}"#).status == .refused)
        #expect(AnthropicRewriteProvider.parse(#"{"stop_reason":"max_tokens","content":[{"type":"text","text":"{\"deci"}]}"#).status == .invalid)
        #expect(AnthropicRewriteProvider.parse(#"{"stop_reason":"end_turn","content":[{"type":"text","text":"not json"}]}"#).status == .invalid)
        #expect(AnthropicRewriteProvider.parse("<html>").status == .invalid)
    }

    @Test func requestUsesStructuredOutputAndFallbacksOnlyWhereSupported() {
        let p = AnthropicRewriteProvider(apiKey: { "k" })
        func req(_ model: String) -> RewriteRequest {
            RewriteRequest(toolName: "WebFetch", toolInput: "{}", segments: ["x"], instructions: [RuleInstruction(name: "n", text: "t")], taskContext: nil, model: model, effort: "low", maxOutputTokens: 100, timeout: 5)
        }
        let haiku = p.requestBody(req("claude-haiku-5-5"))
        #expect(haiku["output_config"]?["format"]?["type"]?.stringValue == "json_schema")
        #expect(haiku["output_config"]?["effort"]?.stringValue == "low")
        #expect(haiku["fallbacks"] == nil)
        #expect(haiku["temperature"] == nil)
        #expect(p.requestBody(req("claude-opus-5-5"))["fallbacks"]?.stringValue == "default")
    }

    @Test func missingKeyFailsWithoutNetwork() async {
        let p = AnthropicRewriteProvider(baseURL: URL(string: "http://127.0.0.1:9")!, apiKey: { nil })
        let r = await p.rewrite(RewriteRequest(toolName: "t", toolInput: "{}", segments: ["x"], instructions: [], taskContext: nil, model: "m", effort: nil, maxOutputTokens: 10, timeout: 1))
        #expect(r.status == .failed)
        #expect(r.error?.contains("No Anthropic API key") == true)
    }
}

@Suite struct ScanTests {
    @Test func scanFindsToolUsesResultsAndTask() throws {
        let s = try ScannedRequest.scan(messagesBody(turns: [("toolu_1", "https://a", "r1"), ("toolu_2", "https://b", "r2")]))
        #expect(s.model == "claude-opus-5-5")
        #expect(s.stream)
        #expect(s.toolResults.map(\.toolUseId) == ["toolu_1", "toolu_2"])
        #expect(s.toolUses["toolu_2"]?.name == "WebFetch")
        #expect(s.taskText == "Compare the headings")
    }
}

// MARK: - Pre-extraction (page stage)

func extractionBody(page: String, prompt: String) -> [UInt8] {
    let text = "\nWeb page content:\n---\n\(page)\n---\n\n\(prompt)\n\nProvide a concise response based only on the content above. In your response:\n - Use quotation marks.\n"
    let encoded = String(decoding: JSONEncoding.string(text), as: UTF8.self)
    return Array(#"{"model":"claude-haiku-5-5","messages":[{"role":"user","content":[{"type":"text","text":\#(encoded)}]}],"system":[{"type":"text","text":"You are a Claude agent."}],"tools":[],"metadata":{"user_id":"u"},"max_tokens":32000,"stream":true}"#.utf8)
}

@Suite struct PageExtractionTests {
    @Test func detectsPageWithInternalRules() throws {
        let page = "Title\n---\nIntro\n\n---\n\nMore text"
        let ex = try #require(ExtractionRequest.detect(extractionBody(page: page, prompt: "What is the title?")))
        #expect(ex.page == page)
        #expect(ex.prompt == "What is the title?")
        #expect(ex.prefix + ex.page + ex.suffix == ex.text)
        #expect(ExtractionRequest.detect(messagesBody(turns: [("toolu_a", "https://e.com", "x")])) == nil)
        #expect(ExtractionRequest.detect(Array(#"{"messages":[{"role":"user","content":"hello"}]}"#.utf8)) == nil)
    }

    func pageProfile(_ store: Store, url: String = "example\\.com") throws -> ProfileVersionInfo {
        try store.createProfile(Profile(name: "page-\(UUID().uuidString.prefix(6))", rules: [
            Rule(id: "p1", name: "Rename on page", match: RuleMatch(tools: ["WebFetch"], input: ["url": url], stage: .page), instructions: "rename"),
        ]))
    }

    @Test func rewritesRawPageAndReplaysRetries() async throws {
        let store = try tempStore()
        let session = try makeSession(store, profile: try pageProfile(store))
        let counter = CallCounter()
        let engine = DecisionEngine(store: store) { countingProvider(counter, ScriptedRewriteProvider.replacing("Example Domain", with: "Morph Test Domain")) }
        await engine.noteToolUses(sessionId: session.id, toolUses: [ToolUseSummary(id: "toolu_w1", name: "WebFetch", input: #"{"url":"https://example.com","prompt":"Heading?"}"#)])
        let body = extractionBody(page: "# Example Domain\n\nThis domain is for examples.", prompt: "Heading?")
        let r = await engine.process(body: body, session: session, exchangeId: 1, requestClass: "auxiliary")
        #expect(r.entries.map(\.handling) == [.decidedRewritten])
        #expect(r.entries.first?.toolUseId == "page:toolu_w1")
        let out = try #require(r.forwardedBody)
        let ex = try #require(ExtractionRequest.detect(out))
        #expect(ex.page == "# Morph Test Domain\n\nThis domain is for examples.")
        #expect(counter.all.first?.toolName.contains("raw page") == true)
        // Only the text string changed: everything after it is byte-identical.
        let tail = #"}]}],"system":[{"type":"text","text":"You are a Claude agent."}],"tools":[],"metadata":{"user_id":"u"},"max_tokens":32000,"stream":true}"#
        #expect(String(decoding: out, as: UTF8.self).hasSuffix(tail))
        // A retried identical request replays without another rewrite call.
        let again = await engine.process(body: body, session: session, exchangeId: 2, requestClass: "auxiliary")
        #expect(again.forwardedBody == out)
        #expect(again.entries.map(\.handling) == [.replayedRewritten])
        #expect(counter.count == 1)
        let detail = try #require(try store.decisionDetail(toolUseId: "page:toolu_w1"))
        #expect(detail.originalText.contains("Example Domain"))
        #expect(detail.toolInput?.contains("example.com") == true)
    }

    @Test func urlPatternsUseTheMatchedFetchAndNonMatchingUrlsPassThrough() async throws {
        let store = try tempStore()
        let session = try makeSession(store, profile: try pageProfile(store, url: "docs\\.example"))
        let counter = CallCounter()
        let engine = DecisionEngine(store: store) { countingProvider(counter, ScriptedRewriteProvider.replacing("Example", with: "X")) }
        await engine.noteToolUses(sessionId: session.id, toolUses: [ToolUseSummary(id: "toolu_w2", name: "WebFetch", input: #"{"url":"https://example.com","prompt":"Q"}"#)])
        let r = await engine.process(body: extractionBody(page: "Example", prompt: "Q"), session: session, exchangeId: 1, requestClass: "auxiliary")
        #expect(r.forwardedBody == nil)
        #expect(r.entries.map(\.handling) == [.decidedUnchanged])
        #expect(counter.count == 0)
    }

    @Test func frozenPageTreatmentIgnoresPromptWording() async throws {
        let store = try tempStore()
        let profile = try pageProfile(store)
        let counter = CallCounter()
        let engine = DecisionEngine(store: store) { countingProvider(counter, ScriptedRewriteProvider.replacing("Example Domain", with: "Morph")) }
        for (i, prompt) in ["What is the heading?", "Tell me the page title", "Summarize"].enumerated() {
            let s = try makeSession(store, profile: profile, scope: "run9:steered")
            await engine.noteToolUses(sessionId: s.id, toolUses: [ToolUseSummary(id: "toolu_t\(i)", name: "WebFetch", input: #"{"url":"https://example.com","prompt":"\#(prompt)"}"#)])
            let r = await engine.process(body: extractionBody(page: "Example Domain page", prompt: prompt), session: s, exchangeId: Int64(i), requestClass: "auxiliary")
            #expect(r.entries.map(\.handling) == [.decidedRewritten])
        }
        #expect(counter.count == 1)
    }

    @Test func stagesAreSeparate() async throws {
        let store = try tempStore()
        // A result-stage rule must not touch extraction requests; a page-stage rule must not touch tool results.
        let resultSession = try makeSession(store, profile: try webProfile(store))
        let engine = DecisionEngine(store: store) { ScriptedRewriteProvider.replacing("Example", with: "X") }
        let r1 = await engine.process(body: extractionBody(page: "Example", prompt: "Q"), session: resultSession, exchangeId: 1, requestClass: "auxiliary")
        #expect(r1.forwardedBody == nil && r1.entries.isEmpty)
        let pageSession = try makeSession(store, profile: try pageProfile(store))
        let r2 = await engine.process(body: messagesBody(turns: [("toolu_s1", "https://example.com", "Example")]), session: pageSession, exchangeId: 2, requestClass: "main")
        #expect(r2.forwardedBody == nil)
        #expect(r2.entries.map(\.handling) == [.decidedUnchanged])
        #expect(throws: StoreError.self) {
            try store.createProfile(Profile(name: "bad", rules: [Rule(name: "r", match: RuleMatch(tools: ["Bash"], stage: .page), instructions: "x")]))
        }
    }
}
