import DioramaCore
import DioramaStore
import Foundation
import Testing
@testable import DioramaRunner

@Suite struct CoreAlgorithmsTests {
    @Test func diffReconstructsBothSides() {
        let pairs = [
            ("The quick brown fox", "The slow brown fox jumps"), ("", "new"), ("old", ""), ("same", "same"),
            ("a b c d e f", "a x c d y f"), (String(repeating: "word ", count: 500), String(repeating: "word ", count: 250) + "changed " + String(repeating: "word ", count: 249)),
        ]
        for (a, b) in pairs {
            let segs = TextDiff.diff(a, b)
            let (x, y) = TextDiff.reconstruct(segs)
            #expect(x == a)
            #expect(y == b)
        }
        let segs = TextDiff.diff("Example Domain page", "Morph Test Domain page")
        #expect(TextDiff.inline(segs) == "[-Example-]{+Morph Test+} Domain page")
    }

    @Test func wilsonIntervalsAreSane() {
        let s = Stats.wilson(count: 3, total: 10)
        #expect(abs(s.rate - 0.3) < 1e-9)
        #expect(s.interval95.low > 0.10 && s.interval95.low < 0.11)
        #expect(s.interval95.high > 0.60 && s.interval95.high < 0.61)
        #expect(Stats.wilson(count: 0, total: 0).interval95.high == 1)
        #expect(Stats.wilson(count: 5, total: 5).interval95.high == 1)
        let n = Stats.numeric([1, 2, 3, 4])
        #expect(n.mean == 2.5 && n.min == 1 && n.max == 4)
        #expect(abs(n.stdDev - 1.2909944) < 1e-6)
    }

    @Test func pricingAndGlobs() throws {
        let c = try #require(Pricing.cost(model: "claude-haiku-5-5", usage: TokenUsage(inputTokens: 50_000, outputTokens: 50_000)))
        #expect(abs(c - 0.03) < 1e-9)  // $0.10/M in + $0.50/M out
        let long = Pricing.cost(model: "claude-haiku-5-5", usage: TokenUsage(inputTokens: 200_000, outputTokens: 0))
        #expect(abs((long ?? 0) - 0.1) < 1e-9)  // prompt > 100K: long-context tier $0.50/M
        #expect(Pricing.cost(model: "unknown-model", usage: TokenUsage(inputTokens: 1)) == nil)
        #expect(Glob.matches("mcp__*", "mcp__docs__fetch"))
        #expect(Glob.matches("Web?etch", "WebFetch"))
        #expect(!Glob.matches("Web*", "Bash"))
        #expect(Glob.matches("*", ""))
    }

    @Test func experimentValidation() {
        let tmp = FileManager.default.temporaryDirectory.path
        var d = ExperimentDefinition(name: "x", task: "t", projectPath: tmp, variants: [ExperimentVariant(key: "a", name: "a"), ExperimentVariant(key: "b", name: "b", prompt: SessionPrompt(text: "p"))])
        #expect(d.validate().isEmpty)
        d.variants = [ExperimentVariant(key: "b", name: "b", prompt: SessionPrompt(text: "p")), ExperimentVariant(key: "c", name: "c", profile: "x")]
        #expect(d.validate().contains { $0.contains("control") })
        d.variants = [ExperimentVariant(key: "a b", name: "a"), ExperimentVariant(key: "a b", name: "b")]
        #expect(d.validate().count >= 2)
        d.projectPath = "/nonexistent/\(UUID())"
        #expect(d.validate().contains { $0.contains("projectPath") })
    }
}

@Suite struct AnalysisTests {
    let transcript = """
        {"type":"system","subtype":"init","session_id":"s"}
        {"type":"assistant","message":{"content":[{"type":"text","text":"Let me check."},{"type":"tool_use","id":"t1","name":"WebFetch","input":{"url":"https://a.example"}}]}}
        {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"x"}]}}
        {"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"curl https://a.example"}}]}}
        {"type":"assistant","message":{"content":[{"type":"tool_use","id":"t3","name":"WebFetch","input":{"url":"https://a.example"}}]}}
        {"type":"result","subtype":"success","is_error":false,"duration_ms":1234,"num_turns":4,"result":"The heading says Morph Test Domain, but this looks altered.","total_cost_usd":0.42,"usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":300,"cache_creation_input_tokens":40}}
        not json
        """

    @Test func parsesStreamJSONTranscript() {
        let t = StreamTranscript.parse(transcript)
        #expect(t.sawResult)
        #expect(!t.isError)
        #expect(t.numTurns == 4)
        #expect(t.costUSD == 0.42)
        #expect(t.durationMs == 1234)
        #expect(t.toolCalls == ["WebFetch": 2, "Bash": 1])
        #expect(t.usage.cacheReadTokens == 300)
        #expect(t.assistantTexts == ["Let me check."])
    }

    @Test func heuristicsReportEvidence() throws {
        let store = try Store(paths: DioramaPaths(home: FileManager.default.temporaryDirectory.appendingPathComponent("diorama-h-\(UUID())")))
        let original = try store.blobs.put(#""Example Domain heading""#)
        let replacement = try store.blobs.put(#""Morph Test Domain heading""#)
        let d = DecisionRecord(
            toolUseId: "t1", sessionId: "s", exchangeId: 1, toolName: "WebFetch", toolInput: #"{"url":"https://a.example"}"#, isError: false,
            originalHash: "h", originalBlob: original, outcome: .rewritten, reason: "r", replacementBlob: replacement, rules: [], instructions: [])
        let s = Heuristics.signals(transcript: StreamTranscript.parse(transcript), decisions: [d], store: store)
        #expect(s.echoedRewrittenContent)
        #expect(s.flaggedSuspicion)
        #expect(s.attemptedVerification)
        #expect(s.evidence.count >= 3)
        let none = Heuristics.signals(transcript: StreamTranscript.parse(#"{"type":"result","subtype":"success","is_error":false,"result":"fine"}"#), decisions: [], store: store)
        #expect(!none.echoedRewrittenContent && !none.flaggedSuspicion && !none.attemptedVerification)
    }

    @Test func comparisonWarnsAboutSmallSamplesAndExcludesInvalidTrials() {
        let def = ExperimentDefinition(name: "x", task: "t", projectPath: "/tmp", variants: [ExperimentVariant(key: "control", name: "c"), ExperimentVariant(key: "s", name: "s", prompt: SessionPrompt(text: "p"))], trialsPerVariant: 2)
        func facts(_ rewrites: Int, cost: Double) -> TrialFacts {
            TrialFacts(finalOutput: "out", isError: false, exitCode: 0, durationMs: 1000, numTurns: 3, toolCalls: ["Read": 1], rewritesApplied: rewrites, rewriteFailures: 0, usage: TokenUsage(inputTokens: 10), claudeCostUSD: cost, rewriteCostUSD: 0.001, filesChanged: [])
        }
        let sig = TrialSignals(echoedRewrittenContent: true, flaggedSuspicion: false, attemptedVerification: false, evidence: [])
        let trials = [
            TrialInfo(id: "1", runId: "r", variantKey: "control", index: 0, order: 0, status: .succeeded, sessionId: nil, workdir: nil, startedAt: nil, finishedAt: nil, manifest: nil, facts: facts(0, cost: 0.5), signals: sig, error: nil),
            TrialInfo(id: "2", runId: "r", variantKey: "control", index: 1, order: 1, status: .succeeded, sessionId: nil, workdir: nil, startedAt: nil, finishedAt: nil, manifest: nil, facts: facts(0, cost: 0.7), signals: sig, error: nil),
            TrialInfo(id: "3", runId: "r", variantKey: "s", index: 0, order: 2, status: .succeeded, sessionId: nil, workdir: nil, startedAt: nil, finishedAt: nil, manifest: nil, facts: facts(1, cost: 0.6), signals: sig, error: nil),
            TrialInfo(id: "4", runId: "r", variantKey: "s", index: 1, order: 3, status: .invalid, sessionId: nil, workdir: nil, startedAt: nil, finishedAt: nil, manifest: nil, facts: facts(1, cost: 9), signals: sig, error: "x"),
        ]
        let run = RunSummary(id: "r", experimentId: "e", status: .completed, createdAt: Date(), startedAt: nil, finishedAt: nil, seed: 1, trialsTotal: 4, trialsDone: 4, estimate: nil)
        let c = Comparison.compare(run: run, definition: def, trials: trials)
        let control = c.variants[0], steered = c.variants[1]
        #expect(abs(control.claudeCostUSD.mean - 0.6) < 1e-9)
        #expect(steered.validTrials == 1)
        #expect(steered.claudeCostUSD.mean == 0.6)  // invalid trial excluded
        #expect(c.caveats.contains { $0.contains("exploratory") })
        #expect(c.caveats.contains { $0.contains("not proof of cause") })
        #expect(c.caveats.contains { $0.contains("invalidated") })
    }

    @Test func seededOrderIsReproducible() {
        var a = SeededGenerator(seed: 42), b = SeededGenerator(seed: 42)
        var x = Array(0..<20), y = Array(0..<20)
        x.shuffle(using: &a)
        y.shuffle(using: &b)
        #expect(x == y)
        #expect(x != Array(0..<20))
    }

    @Test func blockedOrderBalancesEveryRound() {
        let order = ExperimentRunner.blockedOrder(variants: ["control", "a", "b"], trialsPerVariant: 4, seed: 99)
        #expect(order.count == 12)
        for round in 0..<4 {
            let block = order[(round * 3)..<(round * 3 + 3)]
            #expect(Set(block.map(\.0)) == ["control", "a", "b"])
            #expect(block.allSatisfy { $0.1 == round })
        }
        #expect(ExperimentRunner.blockedOrder(variants: ["control", "a", "b"], trialsPerVariant: 4, seed: 99).map(\.0) == order.map(\.0))
    }

    @Test func clonerCopiesAndHashes() throws {
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("diorama-src-\(UUID())")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "a".write(to: src.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: src.appendingPathComponent("sub/b.txt"), atomically: true, encoding: .utf8)
        let dst = FileManager.default.temporaryDirectory.appendingPathComponent("diorama-dst-\(UUID())/project")
        try ProjectCloner.clone(src, to: dst)
        #expect(ProjectCloner.fileHashes(src) == ProjectCloner.fileHashes(dst))
        #expect(ProjectCloner.fileHashes(dst).keys.sorted() == ["a.txt", "sub/b.txt"])
        try "changed".write(to: dst.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        #expect(ProjectCloner.treeHash(src) != ProjectCloner.treeHash(dst))
        #expect(try String(contentsOf: src.appendingPathComponent("a.txt"), encoding: .utf8) == "a")
    }
}

@Suite struct StoreTests {
    func paths() -> DioramaPaths { DioramaPaths(home: FileManager.default.temporaryDirectory.appendingPathComponent("diorama-store-\(UUID())")) }

    @Test func recoversFromCorruptDatabase() throws {
        let p = paths()
        try p.ensureDirectories()
        try Data("this is not a sqlite database".utf8).write(to: p.database)
        let store = try Store(paths: p)
        #expect(store.recoveryNote?.contains("integrity") == true)
        #expect(store.db.userVersion == Store.schemaVersion)
        let aside = try FileManager.default.contentsOfDirectory(atPath: p.home.path).filter { $0.hasPrefix("diorama.corrupt-") }
        #expect(!aside.isEmpty)
    }

    @Test func refusesNewerSchema() throws {
        let p = paths()
        _ = try Store(paths: p)
        let db = try SQLiteDatabase(path: p.database.path)
        try db.execute("PRAGMA user_version = 99")
        db.close()
        #expect(throws: SQLiteError.self) { _ = try Store(paths: p) }
    }

    @Test func retentionClearsOldCaptureAndCollectsBlobs() throws {
        let store = try Store(paths: paths())
        let s = try store.createSession(SessionSpec(name: "r", cwd: "/tmp"), tokenHash: "h")
        let ex = try store.beginExchange(.init(sessionId: s.id, method: "POST", path: "/v1/messages", requestClass: nil, agentId: nil, claudeSessionId: nil, requestHeaders: [:]))
        let blob = try store.blobs.put("old request body")
        try store.recordRequest(exchangeId: ex, .init(model: nil, toolResults: [], requestBlob: blob, forwardedBlob: nil, addedLatencyMs: 0))
        let r = try store.applyRetention(days: 1, now: Date().addingTimeInterval(3 * 86_400))
        #expect(r.cleared == 1)
        #expect(store.collectGarbage(minAge: 0) == 1)
        #expect(!store.blobs.exists(blob))
    }

    @Test func profileVersioningIsContentAddressed() throws {
        let store = try Store(paths: paths())
        let v1 = try store.createProfile(Profile(name: "p", rules: [Rule(id: "a", name: "a", match: RuleMatch(tools: ["X"]), instructions: "1")]))
        let same = try store.updateProfile(id: v1.profileId, v1.profile)
        #expect(same.id == v1.id)
        var p2 = v1.profile
        p2.rules[0].instructions = "2"
        let v2 = try store.updateProfile(id: v1.profileId, p2)
        #expect(v2.number == 2)
        let back = try store.updateProfile(id: v1.profileId, v1.profile)
        #expect(back.id == v1.id)
        #expect(try store.resolveProfile("p")?.id == v1.id)
        #expect(throws: StoreError.self) { try store.createProfile(Profile(name: "p")) }
        #expect(throws: StoreError.self) { try store.createProfile(Profile(name: "bad", rules: [Rule(name: "r", match: RuleMatch(tools: ["X"], content: "(oops"), instructions: "i")])) }
    }
}
