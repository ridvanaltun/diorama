import DioramaCore
import DioramaJSON
import DioramaStore
import Foundation
import Testing
@testable import DioramaEngine

@Suite struct RedactorTests {
    @Test func masksKnownSecretFormatsOnly() {
        let key = "sk-ant-api03-" + String(repeating: "a", count: 40)
        let text = """
            ANTHROPIC_API_KEY=\(key)
            aws AKIAIOSFODNN7EXAMPLE and ghp_\(String(repeating: "b", count: 36))
            Authorization: Bearer abcdefghijklmnopqrstuvwxyz0123
            -----BEGIN RSA PRIVATE KEY-----
            MIIEowIBAAKCAQEA
            -----END RSA PRIVATE KEY-----
            The task-ant colony shows risk-taking; sk-short isn't a key. Mail me@example.com from 10.0.0.1.
            """
        let r = Redactor.apply([RedactSpec(presets: [.secrets])], to: [text])
        let out = r.texts[0]
        #expect(!out.contains(key) && out.contains("[REDACTED:anthropic-key]"))
        #expect(out.contains("[REDACTED:aws-access-key]") && out.contains("[REDACTED:github-token]") && out.contains("[REDACTED:bearer-token]"))
        #expect(out.contains("[REDACTED:private-key]") && !out.contains("MIIEowIBAAKCAQEA"))
        #expect(out.contains("The task-ant colony shows risk-taking; sk-short isn't a key."), "ordinary text stays")
        #expect(out.contains("me@example.com") && out.contains("10.0.0.1"), "emails and IPs only with their presets")
        #expect(r.total == 5)
        #expect(r.summary == "redacted 5 matches (anthropic-key ×1, aws-access-key ×1, bearer-token ×1, github-token ×1, private-key ×1)")

        let pii = Redactor.apply([RedactSpec(presets: [.emails, .ipAddresses], patterns: ["ACME-\\d+"])], to: ["me@example.com via 10.0.0.1 for ACME-42", "nothing"])
        #expect(pii.texts == ["[REDACTED:email] via [REDACTED:ip-address] for [REDACTED:custom]", "nothing"])
        #expect(Redactor.apply([RedactSpec(presets: [], patterns: ["(oops"])], to: ["x"]).total == 0, "invalid patterns are skipped")
    }

    @Test func rulesWithoutRedactionKeepTheirHash() throws {
        let r = Rule(id: "r", name: "n", match: RuleMatch(tools: ["WebFetch"]), instructions: "i")
        let json = String(decoding: try DioramaCoding.encoder.encode(r), as: UTF8.self)
        #expect(!json.contains("redact"), "older rules encode (and hash) exactly as before")
        let decoded = try DioramaCoding.decoder.decode(Rule.self, from: Data(#"{"name":"r","match":{"tools":["*"]},"redact":{"presets":["secrets"]}}"#.utf8))
        #expect(decoded.isRedaction && decoded.instructions.isEmpty)
    }
}

@Suite struct RedactionEngineTests {
    let secret = "sk-ant-api03-" + String(repeating: "z", count: 40)

    func session(_ store: Store, rules: [Rule]) throws -> SessionRecord {
        let p = try store.createProfile(Profile(name: "p-\(UUID().uuidString.prefix(6))", rules: rules))
        return try makeSession(store, profile: p)
    }

    @Test func redactionAloneNeedsNoAgent() async throws {
        let store = try tempStore()
        let counter = CallCounter()
        let engine = DecisionEngine(store: store) { countingProvider(counter, .replacing("x", with: "y")) }
        let s = try session(store, rules: [Rule(name: "Redact", match: RuleMatch(tools: ["WebFetch"]), instructions: "", redact: RedactSpec())])
        let r = await engine.process(body: messagesBody(turns: [(id: "toolu_r1", url: "https://example.com", result: "key: \(secret)")]), session: s, exchangeId: 1, requestClass: "main")
        let forwarded = String(decoding: try #require(r.forwardedBody), as: UTF8.self)
        #expect(!forwarded.contains(secret) && forwarded.contains("[REDACTED:anthropic-key]"))
        #expect(try store.decision(toolUseId: "toolu_r1")?.reason == "redacted 1 match (anthropic-key ×1)")
        #expect(counter.count == 0)
    }

    @Test func theAgentOnlySeesRedactedTextAndRedactionSurvivesFailure() async throws {
        let store = try tempStore()
        let counter = CallCounter()
        let failing = ScriptedRewriteProvider { req in
            counter.record(req)
            return RewriteResponse(status: .failed, error: "HTTP 500")
        }
        let engine = DecisionEngine(store: store) { failing }
        let s = try session(store, rules: [
            Rule(name: "Redact", match: RuleMatch(tools: ["*"]), instructions: "", redact: RedactSpec()),
            Rule(name: "Rewrite", match: RuleMatch(tools: ["WebFetch"]), instructions: "rename"),
        ])
        let r = await engine.process(body: messagesBody(turns: [(id: "toolu_r2", url: "https://example.com", result: "Example Domain \(secret)")]), session: s, exchangeId: 1, requestClass: "main")
        #expect(counter.all.allSatisfy { !$0.segments.joined().contains(secret) }, "secrets never reach the rewrite agent")
        #expect(counter.all.first?.instructions.map(\.name) == ["Rewrite"])
        let forwarded = String(decoding: try #require(r.forwardedBody), as: UTF8.self)
        #expect(!forwarded.contains(secret), "a failed rewrite still forwards the redacted text")
        let d = try #require(try store.decision(toolUseId: "toolu_r2"))
        #expect(d.outcome == .rewritten && d.reason.contains("only the redaction was applied"))

        // Over budget: no agent call, but the redaction still applies.
        var settings = store.settings()
        settings.dailyBudgetUSD = 0
        try store.saveSettings(settings)
        let calls = counter.count
        let b = await engine.process(body: messagesBody(turns: [(id: "toolu_r3", url: "https://example.com", result: "again \(secret)")]), session: s, exchangeId: 2, requestClass: "main")
        #expect(!String(decoding: try #require(b.forwardedBody), as: UTF8.self).contains(secret))
        #expect(try store.decision(toolUseId: "toolu_r3")?.reason.contains("not rewritten further") == true)
        #expect(counter.count == calls)
    }

    @Test func playgroundPreviewsRedactionForFree() async throws {
        let store = try tempStore()
        let counter = CallCounter()
        let engine = DecisionEngine(store: store) { countingProvider(counter, .replacing("x", with: "y")) }
        let result = await engine.playground(rules: [Rule(name: "Redact", match: RuleMatch(tools: ["*"]), instructions: "", redact: RedactSpec())],
                                             defaults: ProfileDefaults(), toolName: "Bash", toolInputJSON: nil, segments: ["export KEY=\(secret)"], stage: .result, rewrite: false)
        #expect(result.model == nil)
        #expect(result.rewrite?.replacementText == "export KEY=[REDACTED:anthropic-key]")
        #expect(result.rewrite?.model == "local redaction")
        #expect(counter.count == 0)
    }
}
