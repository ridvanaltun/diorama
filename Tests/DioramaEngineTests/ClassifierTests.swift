import DioramaCore
import DioramaJSON
import DioramaStore
import Foundation
import Testing
@testable import DioramaEngine

final class ClassifyLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ClassifyRequest] = []
    func add(_ r: ClassifyRequest) { lock.withLock { items.append(r) } }
    var all: [ClassifyRequest] { lock.withLock { items } }
}

@Suite struct ClassifierTests {
    /// Says yes when the content mentions a price; fails on "boom".
    func provider(_ log: ClassifyLog, _ rewrites: CallCounter) -> ScriptedRewriteProvider {
        ScriptedRewriteProvider(classifier: { req in
            log.add(req)
            if req.content.contains("boom") { return ClassifyResponse(answer: nil, error: "HTTP 500") }
            let yes = req.content.lowercased().contains("price")
            return ClassifyResponse(answer: yes, reason: yes ? "mentions a price" : "no price here", modelServed: "scripted", usage: TokenUsage(inputTokens: 50, outputTokens: 5))
        }) { req in
            rewrites.record(req)
            return await ScriptedRewriteProvider.replacing("10", with: "12").rewrite(req)
        }
    }

    func session(_ store: Store, extra: [Rule] = []) throws -> SessionRecord {
        let p = try store.createProfile(Profile(name: "c-\(UUID().uuidString.prefix(6))", rules: extra + [
            Rule(name: "Raise prices", match: RuleMatch(tools: ["WebFetch"], classifier: RuleClassifier(question: "Does this page state a price?")), instructions: "raise prices"),
        ]))
        return try makeSession(store, profile: p)
    }

    @Test func rewritesOnlyWhenTheClassifierSaysYes() async throws {
        let store = try tempStore()
        let log = ClassifyLog(), rewrites = CallCounter()
        let engine = DecisionEngine(store: store) { provider(log, rewrites) }
        let s = try session(store)
        let body = messagesBody(turns: [(id: "toolu_c1", url: "https://shop.example", result: "The price is 10 dollars"),
                                        (id: "toolu_c2", url: "https://blog.example", result: "Nothing about money, 10 tips"),
                                        (id: "toolu_c3", url: "https://x.example", result: "boom")])
        _ = await engine.process(body: body, session: s, exchangeId: 1, requestClass: "main")
        #expect(try store.decision(toolUseId: "toolu_c1")?.outcome == .rewritten)
        let no = try #require(try store.decision(toolUseId: "toolu_c2"))
        #expect(no.outcome == .unchanged && no.reason.contains("“Does this page state a price?”: no — no price here"))
        let failed = try #require(try store.decision(toolUseId: "toolu_c3"))
        #expect(failed.outcome == .unchanged && failed.reason.contains("failed (HTTP 500)"), "a failed classification never rewrites")
        #expect(rewrites.count == 1)
        #expect(log.all.first?.question == "Does this page state a price?")
        // Each verdict is an attempt in the audit trail, and its cost counts as spending.
        let attempts = try store.attempts(toolUseId: "toolu_c2")
        #expect(attempts.map(\.mode) == ["classify"] && attempts.first?.explanation?.hasPrefix("Classifier (Raise prices): no") == true)
        #expect(try store.decisionDetail(toolUseId: "toolu_c1")?.instructions.contains { $0.contains("Classifier") && $0.contains(": yes") } == true)
    }

    @Test func classifiersSeeRedactedContentAndThePlaygroundRunsThemOnDemand() async throws {
        let store = try tempStore()
        let log = ClassifyLog(), rewrites = CallCounter()
        let engine = DecisionEngine(store: store) { provider(log, rewrites) }
        let secret = "sk-ant-api03-" + String(repeating: "q", count: 40)
        let s = try session(store, extra: [Rule(name: "Redact", match: RuleMatch(tools: ["*"]), instructions: "", redact: RedactSpec())])
        _ = await engine.process(body: messagesBody(turns: [(id: "toolu_c4", url: "https://shop.example", result: "price 10, key \(secret)")]), session: s, exchangeId: 1, requestClass: "main")
        #expect(log.all.allSatisfy { !$0.content.contains(secret) })

        let rules = [Rule(id: "r", name: "Raise prices", match: RuleMatch(tools: ["*"], classifier: RuleClassifier(question: "Price?")), instructions: "raise")]
        let check = await engine.playground(rules: rules, defaults: ProfileDefaults(), toolName: "WebFetch", toolInputJSON: nil, segments: ["price 10"], stage: .result, rewrite: false)
        #expect(check.checks.first?.reason.contains("classifier question runs when you run the rewrite") == true)
        let before = log.all.count
        let run = await engine.playground(rules: rules, defaults: ProfileDefaults(), toolName: "WebFetch", toolInputJSON: nil, segments: ["no money here"], stage: .result, rewrite: true)
        #expect(log.all.count == before + 1)
        #expect(run.checks.first?.matches == false && run.checks.first?.reason == "classifier: no — no price here")
        #expect(run.rewrite == nil && run.note?.contains("classifier didn't say yes") == true)
    }
}
