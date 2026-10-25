import DioramaCore
import DioramaJSON
import DioramaStore
import Foundation

/// Outcome of processing one outgoing request.
public struct ProcessResult: Sendable {
    /// Bytes to forward upstream; nil means forward the original bytes unchanged.
    public var forwardedBody: [UInt8]?
    public var entries: [ToolResultEntry]
    public var model: String?
    public var scanError: String?
}

/// Applies Diorama's core invariant: the first decision for a `tool_use_id` is frozen and
/// every later request carries exactly the same bytes for it (decisions D9/D10).
public final class DecisionEngine: Sendable {
    let store: Store
    let providerFor: @Sendable (_ model: String) -> RewriteProvider
    let inflight = Inflight()
    let treatmentLock = KeyedLock()
    /// Rewrites held for the user's approval (review mode).
    public let reviews = ReviewCenter()
    let anomalies = AnomalyMemory()
    let pendingFetches = PendingFetches()

    /// `provider` picks the backend for a model id (e.g. `ollama:` models go to a local server).
    public init(store: Store, provider: @escaping @Sendable (_ model: String) -> RewriteProvider) {
        self.store = store
        self.providerFor = provider
    }

    /// Convenience for a single backend regardless of model.
    public convenience init(store: Store, provider: @escaping @Sendable () -> RewriteProvider) {
        self.init(store: store, provider: { (_: String) in provider() })
    }

    actor Inflight {
        var tasks: [String: Task<DecisionRecord, Never>] = [:]

        func decision(for id: String, make: @escaping @Sendable () async -> DecisionRecord) async -> DecisionRecord {
            if let t = tasks[id] { return await t.value }
            let t = Task { await make() }
            tasks[id] = t
            let value = await t.value
            tasks[id] = nil
            return value
        }
    }

    /// Serializes work per key (async-safe mutex). Used so concurrent experiment trials that
    /// share a frozen treatment make one rewrite instead of racing to make several.
    actor KeyedLock {
        private var held = Set<String>()
        private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

        func lock(_ key: String) async {
            if held.contains(key) {
                await withCheckedContinuation { waiters[key, default: []].append($0) }
            } else {
                held.insert(key)
            }
        }

        func unlock(_ key: String) {
            if var w = waiters[key], !w.isEmpty {
                let next = w.removeFirst()
                waiters[key] = w.isEmpty ? nil : w
                next.resume()  // ownership passes to the next waiter
            } else {
                held.remove(key)
            }
        }
    }

    actor AnomalyMemory {
        var seen = Set<String>()
        func firstTime(_ key: String) -> Bool { seen.insert(key).inserted }
    }

    // MARK: - Request processing

    public func process(
        body: [UInt8], session: SessionRecord, exchangeId: Int64, requestClass: String?, allowNewDecisions: Bool = true
    ) async -> ProcessResult {
        let scan: ScannedRequest
        do {
            scan = try ScannedRequest.scan(body)
        } catch {
            if await anomalies.firstTime("scan:\(session.id)") {
                store.addEvent(sessionId: session.id, kind: .anomaly, message: "Could not parse a request body; forwarded unchanged (\(error))", refId: String(exchangeId))
            }
            return ProcessResult(forwardedBody: nil, entries: [], model: nil, scanError: String(describing: error))
        }
        if scan.toolResults.isEmpty, allowNewDecisions,
           let page = await processExtraction(body: body, session: session, exchangeId: exchangeId, requestClass: requestClass) {
            var result = page
            result.model = scan.model
            return result
        }
        let ids = scan.toolResults.map(\.toolUseId)
        let existing = (try? store.decisions(toolUseIds: ids)) ?? [:]
        var replacements: [(range: Range<Int>, bytes: [UInt8])] = []
        var entries: [ToolResultEntry] = []
        var replayed: [String] = []
        var pending: [(index: Int, result: ScannedToolResult, original: [UInt8], hash: String)] = []

        for tr in scan.toolResults {
            let name = scan.toolUses[tr.toolUseId]?.name
            guard let content = tr.content, tr.contentKind == .string || tr.contentKind == .blocks else {
                entries.append(ToolResultEntry(toolUseId: tr.toolUseId, toolName: name, handling: .skipped))
                continue
            }
            let original = Array(body[content.range])
            let hash = Hashing.sha256Hex(original)
            if let d = existing[tr.toolUseId] {
                if d.originalHash == hash {
                    replayed.append(d.toolUseId)
                    switch d.outcome {
                    case .rewritten:
                        if let blob = d.replacementBlob, let bytes = try? store.blobs.get(blob) {
                            replacements.append((content.range, bytes))
                            entries.append(ToolResultEntry(toolUseId: tr.toolUseId, toolName: name, handling: .replayedRewritten))
                        } else {
                            // The replacement blob is missing: never silently fall back to the original.
                            entries.append(ToolResultEntry(toolUseId: tr.toolUseId, toolName: name, handling: .clientModified))
                            if await anomalies.firstTime("blob:\(d.toolUseId)") {
                                store.addEvent(sessionId: session.id, kind: .anomaly, message: "Stored rewrite for \(d.toolUseId) is missing; the original was forwarded", refId: d.toolUseId)
                                try? store.addFlag(sessionId: session.id, "replay-integrity")
                            }
                        }
                    case .unchanged:
                        entries.append(ToolResultEntry(toolUseId: tr.toolUseId, toolName: name, handling: .replayedUnchanged))
                    case .failed:
                        entries.append(ToolResultEntry(toolUseId: tr.toolUseId, toolName: name, handling: .replayedFailed))
                    }
                } else {
                    entries.append(ToolResultEntry(toolUseId: tr.toolUseId, toolName: name, handling: .clientModified))
                    if await anomalies.firstTime("mod:\(d.toolUseId):\(hash)") {
                        store.addEvent(
                            sessionId: session.id, kind: .anomaly,
                            message: "Claude Code changed the content of \(name ?? "tool") result \(d.toolUseId) after it was decided; forwarded Claude Code's version",
                            refId: d.toolUseId)
                    }
                }
            } else if allowNewDecisions {
                entries.append(ToolResultEntry(toolUseId: tr.toolUseId, toolName: name, handling: .skipped))
                pending.append((entries.count - 1, tr, original, hash))
            } else {
                entries.append(ToolResultEntry(toolUseId: tr.toolUseId, toolName: name, handling: .skipped))
            }
        }

        // New tool results are decided concurrently (deduplicated per tool_use_id).
        if !pending.isEmpty {
            let decided = await withTaskGroup(of: (Int, DecisionRecord, Range<Int>).self) { group in
                for p in pending {
                    let content = p.result.content!
                    group.addTask {
                        let target = self.toolResultTarget(p.result, original: p.original, hash: p.hash, scan: scan, body: body)
                        let d = await self.inflight.decision(for: p.result.toolUseId) {
                            await self.decide(target, session: session, exchangeId: exchangeId, requestClass: requestClass)
                        }
                        return (p.index, d, content.range)
                    }
                }
                var out: [(Int, DecisionRecord, Range<Int>)] = []
                for await r in group { out.append(r) }
                return out
            }
            for (index, d, range) in decided {
                let name = entries[index].toolName
                switch d.outcome {
                case .rewritten:
                    if let blob = d.replacementBlob, let bytes = try? store.blobs.get(blob) {
                        replacements.append((range, bytes))
                        entries[index] = ToolResultEntry(toolUseId: d.toolUseId, toolName: name, handling: .decidedRewritten)
                    } else {
                        entries[index] = ToolResultEntry(toolUseId: d.toolUseId, toolName: name, handling: .decidedFailed)
                    }
                case .unchanged: entries[index] = ToolResultEntry(toolUseId: d.toolUseId, toolName: name, handling: .decidedUnchanged)
                case .failed: entries[index] = ToolResultEntry(toolUseId: d.toolUseId, toolName: name, handling: .decidedFailed)
                }
            }
        }
        store.incrementReplays(replayed)

        guard !replacements.isEmpty else { return ProcessResult(forwardedBody: nil, entries: entries, model: scan.model) }
        do {
            let out = try JSONSplice.apply(body, replacements)
            return ProcessResult(forwardedBody: out, entries: entries, model: scan.model)
        } catch {
            store.addEvent(sessionId: session.id, kind: .anomaly, message: "Splice failed (\(error)); forwarded unchanged", refId: String(exchangeId))
            return ProcessResult(forwardedBody: nil, entries: entries, model: scan.model, scanError: String(describing: error))
        }
    }

    // MARK: - Deciding a new tool result

    struct Applicable {
        var rules: [Rule]
        var refs: [RuleRef]
        var defaults: ProfileDefaults
    }

    func applicableRules(session: SessionRecord, ctx: MatchContext) -> Applicable {
        let defaults = session.profileVersion?.profile.defaults ?? ProfileDefaults(model: store.settings().defaultModel)
        var rules: [Rule] = []
        var refs: [RuleRef] = []
        for r in session.profileVersion?.profile.rules ?? [] where RuleMatcher.matches(r, ctx) {
            rules.append(r)
            refs.append(RuleRef(ruleId: r.id, name: r.name, ruleHash: RuleMatcher.ruleHash(r), profileVersionId: session.profileVersion?.id))
        }
        if let prompt = session.prompt {
            let rule = prompt.asRule(id: "session-prompt")
            if RuleMatcher.matches(rule, ctx) {
                rules.append(rule)
                refs.append(RuleRef(ruleId: rule.id, name: rule.name, ruleHash: RuleMatcher.ruleHash(rule), profileVersionId: nil))
            }
        }
        return Applicable(rules: rules, refs: refs, defaults: defaults)
    }

    /// Everything `decide` needs about one thing that may be rewritten: a tool result, or (in
    /// pre-extraction mode) the raw page inside WebFetch's summarizing request.
    struct DecisionTarget: Sendable {
        var decisionId: String
        var toolName: String?
        var toolInputJSON: String?
        /// Fields rules match against (`match.input`).
        var matchInput: JSONValue
        /// Fields that identify the treatment across trials (frozen treatment key).
        var treatmentInput: JSONValue
        var isError: Bool
        var stage: RuleStage
        /// Bytes stored as the decision's original blob.
        var original: [UInt8]
        var hash: String
        var segments: [String]
        var taskText: String?
        var missingReason: String?
        /// Builds the bytes stored as the replacement blob from the new segment texts.
        var buildReplacement: @Sendable ([String]) throws -> [UInt8]
    }

    func toolResultTarget(_ tr: ScannedToolResult, original: [UInt8], hash: String, scan: ScannedRequest, body: [UInt8]) -> DecisionTarget {
        let toolUse = scan.toolUses[tr.toolUseId]
        let input = toolUse.flatMap { try? JSONValue.parse($0.inputJSON) } ?? .object([:])
        let content = tr.content!
        let nodes = tr.textSegments
        return DecisionTarget(
            decisionId: tr.toolUseId, toolName: toolUse?.name, toolInputJSON: toolUse?.inputJSON, matchInput: input, treatmentInput: input,
            isError: tr.isError, stage: .result, original: original, hash: hash,
            segments: nodes.compactMap { try? JSONIndex.decodeString(body, $0) }, taskText: scan.taskText,
            missingReason: toolUse == nil ? "no matching tool_use block in the request" : nil,
            buildReplacement: { try Self.replacementBytes(body: body, content: content, segments: nodes, newTexts: $0) })
    }

    func decide(_ t: DecisionTarget, session: SessionRecord, exchangeId: Int64, requestClass: String?) async -> DecisionRecord {
        // A concurrent request may already have decided this id: the first decision wins.
        if let existing = try? store.decision(toolUseId: t.decisionId) { return existing }
        let originalBlob = (try? store.blobs.put(t.original)) ?? t.hash
        let label = "\(t.toolName ?? "tool") " + (t.stage == .page ? "page" : t.stage == .input ? "input" : "result")
        func record(_ outcome: DecisionOutcome, _ reason: String, replacement: String? = nil, refs: [RuleRef] = [], instructions: [String] = [], treatmentKey: String? = nil) -> DecisionRecord {
            let d = DecisionRecord(
                toolUseId: t.decisionId, sessionId: session.id, exchangeId: exchangeId, toolName: t.toolName, toolInput: t.toolInputJSON,
                isError: t.isError, originalHash: t.hash, originalBlob: originalBlob, outcome: outcome, reason: reason,
                replacementBlob: replacement, rules: refs, instructions: instructions, treatmentKey: treatmentKey)
            // Persisted before the request is forwarded (FR-19). If persistence fails we must not
            // rewrite, because the rewrite could not be replayed.
            guard let saved = try? store.insertDecision(d) else {
                store.addEvent(sessionId: session.id, kind: .anomaly, message: "Could not persist decision for \(t.decisionId); forwarded unchanged", refId: t.decisionId)
                var fallback = d
                fallback.outcome = .failed
                fallback.replacementBlob = nil
                fallback.reason = "decision could not be persisted"
                return fallback
            }
            if saved.outcome == .rewritten || saved.outcome == .failed {
                store.addEvent(sessionId: session.id, kind: saved.outcome == .failed ? .rewriteFailed : .decisionMade,
                               message: "\(label) \(saved.outcome.rawValue): \(saved.reason)", refId: saved.toolUseId)
            } else {
                store.addEvent(sessionId: session.id, kind: .decisionMade, message: "\(label) unchanged: \(saved.reason)", refId: saved.toolUseId)
            }
            return saved
        }

        if let missing = t.missingReason { return record(.unchanged, missing) }
        guard let toolName = t.toolName else { return record(.unchanged, "unknown tool") }
        guard !t.segments.isEmpty else { return record(.unchanged, "tool result has no text content") }
        var segments = t.segments
        let text = segments.joined(separator: "\n\n")
        let ctx = MatchContext(toolName: toolName, toolInput: t.matchInput, text: text, requestClass: requestClass, isError: t.isError, stage: t.stage,
                               sampleId: t.decisionId)
        let app = applicableRules(session: session, ctx: ctx)
        if app.rules.isEmpty {
            let hasRules = !(session.profileVersion?.profile.rules.isEmpty ?? true) || session.prompt != nil
            // Rules that match except for their sample: say so, so the audit shows sampling at work.
            var unsampled = ctx
            unsampled.sampleId = nil
            let skipped = (session.profileVersion?.profile.rules ?? []).filter { r in
                (r.match.sample ?? 1) < 1 && !RuleMatcher.matches(r, ctx) && RuleMatcher.matches(r, unsampled)
            }
            if !skipped.isEmpty {
                return record(.unchanged, "not in the sample of " + skipped.map { "“\($0.name)” (\(RuleMatcher.percent($0.match.sample ?? 1)))" }.joined(separator: ", "))
            }
            return record(.unchanged, hasRules ? "no rule matched" : "no rules configured")
        }
        var rewriteRules = app.rules.filter { !$0.isRedaction }
        var instructions = rewriteRules.map { RuleInstruction(name: $0.name, text: $0.instructions) }
        var instructionTexts = app.rules.map { r in
            r.redact.map { "[\(r.name)] Redact \($0.summary) (local, no AI)" } ?? "[\(r.name)] \(r.instructions)"
        }

        // Redaction first: local and free, and the rewrite agent only ever sees the redacted text.
        var redaction: Redactor.Result?
        let redactSpecs = app.rules.compactMap(\.redact)
        if !redactSpecs.isEmpty {
            let r = Redactor.apply(redactSpecs, to: segments)
            if r.total > 0 {
                redaction = r
                segments = r.texts
            }
        }
        /// Records the redacted content alone (no rules left for the agent, or it couldn't run). A redaction
        /// is never dropped because a rewrite failed: Claude gets the redacted text either way.
        func recordRedacted(_ note: String?) -> DecisionRecord {
            guard let r = redaction else {
                return record(.unchanged, note ?? "nothing to redact", refs: app.refs, instructions: instructionTexts)
            }
            guard let bytes = try? t.buildReplacement(segments), let blob = try? store.blobs.put(bytes) else {
                return record(.failed, "could not build the redacted content — original forwarded", refs: app.refs, instructions: instructionTexts)
            }
            return record(.rewritten, r.summary + (note.map { "; \($0)" } ?? ""), replacement: blob, refs: app.refs, instructions: instructionTexts)
        }
        if rewriteRules.isEmpty { return recordRedacted(nil) }
        if text.count > app.defaults.maxInputChars {
            let why = "content too large to rewrite (\(text.count) > \(app.defaults.maxInputChars) characters)"
            return redaction != nil ? recordRedacted(why) : record(.unchanged, why, refs: app.refs, instructions: instructionTexts)
        }

        // Paused steering (this session, or everywhere): no AI rewrites or input changes; redaction still applies.
        // Experiment trials are exempt; pausing one mid-run would corrupt the experiment.
        if session.trialId == nil, store.settings().steeringPaused || store.isPaused(sessionId: session.id) {
            let scope = store.settings().steeringPaused ? "steering is paused everywhere" : "steering is paused for this session"
            return redaction != nil ? recordRedacted("not rewritten further: \(scope)")
                : record(.unchanged, "not rewritten: \(scope)", refs: app.refs, instructions: instructionTexts)
        }

        // Budget guard: interactive sessions stop calling the rewrite agent once a daily cap is used up.
        // Experiment trials are exempt; they run against their own approved estimate.
        if session.trialId == nil,
           let why = budgetBlock(profileId: session.profileId, profileBudget: session.profileVersion?.profile.defaults.dailyBudgetUSD) {
            try? store.addFlag(sessionId: session.id, "budget-reached")
            let day = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
            if await anomalies.firstTime("budget:\(session.id):\(day)") {
                store.addEvent(sessionId: session.id, kind: .warning,
                               message: "Rewrites paused: \(why). Matching tool results are forwarded unchanged until tomorrow, or until you raise the budget.",
                               refId: t.decisionId)
            }
            return redaction != nil ? recordRedacted("not rewritten further: \(why)")
                : record(.unchanged, "not rewritten: \(why)", refs: app.refs, instructions: instructionTexts)
        }

        // Content-aware matching: rules with a classifier apply only if a cheap model answers "yes".
        // A failed classification counts as "no": nothing is rewritten on a guess.
        if rewriteRules.contains(where: { $0.match.classifier != nil }) {
            var kept: [Rule] = []
            var verdicts: [String] = []
            for r in rewriteRules {
                guard let c = r.match.classifier else {
                    kept.append(r)
                    continue
                }
                let v = await classify(c, rule: r, toolName: toolName, toolInput: t.toolInputJSON ?? "{}", content: segments.joined(separator: "\n\n"),
                                       defaults: app.defaults, decisionId: t.decisionId, sessionId: session.id)
                if v.answer == true { kept.append(r) }
                let answer = v.answer.map { $0 ? "yes" : "no" } ?? "failed (\(v.error ?? "unknown error"))"
                verdicts.append("[\(r.name)] Classifier “\(c.question)”: \(answer)" + (v.reason.map { " — \($0)" } ?? ""))
            }
            instructionTexts += verdicts
            rewriteRules = kept
            instructions = kept.map { RuleInstruction(name: $0.name, text: $0.instructions) }
            if kept.isEmpty {
                let why = "the classifier didn't say yes (" + verdicts.joined(separator: "; ") + ")"
                return redaction != nil ? recordRedacted(why) : record(.unchanged, why, refs: app.refs, instructions: instructionTexts)
            }
        }

        // Frozen experiment treatment: identical inputs reuse the stored rewrite (decision D11).
        // Trials running in parallel wait for the first one's rewrite instead of racing.
        var treatmentKey: String?
        if let scope = session.treatmentScope {
            treatmentKey = Hashing.sha256Hex([scope, RewritePrompt.version, t.stage.rawValue, app.refs.map(\.ruleHash).joined(separator: ","), toolName, t.treatmentInput.canonicalString, t.hash].joined(separator: "\u{1F}"))
        }

        func rewriteNow() async -> DecisionRecord {
            let model = rewriteRules.last(where: { $0.model != nil })?.model ?? app.defaults.model
            let effort = rewriteRules.last(where: { $0.effort != nil })?.effort ?? app.defaults.effort
            let wantsTask = rewriteRules.contains { $0.context == .task }
            var request = RewriteRequest(
                toolName: Self.agentToolLabel(toolName, t.stage), toolInput: t.toolInputJSON ?? "{}",
                segments: segments, instructions: instructions, taskContext: wantsTask ? t.taskText : nil, model: model, effort: effort,
                maxOutputTokens: app.defaults.maxOutputTokens, timeout: app.defaults.timeoutSeconds)

            let provider = providerFor(model)
            let started = Date()
            let budget = max(app.defaults.timeoutSeconds * 2, 30)
            var lastError = "rewrite failed"
            for attempt in 0..<2 {
                let response = await provider.rewrite(request)
                let attemptId = Hashing.newId(prefix: "att")
                var status = response.status
                var error = response.error
                var newSegments: [String]?
                if let output = response.output, status == .succeeded || status == .unchanged {
                    switch EditApplication.apply(output, to: segments) {
                    case .success(let s):
                        newSegments = s
                        if s == segments { status = .unchanged }
                    case .failure(let e):
                        status = .invalid
                        error = e.description
                    }
                }
                let cost = response.usage.flatMap { Pricing.cost(model: response.modelServed ?? model, usage: $0) }
                let info = RewriteAttemptInfo(
                    id: attemptId, provider: provider.id, modelRequested: model, modelServed: response.modelServed, promptVersion: RewritePrompt.version,
                    status: status, error: error, usage: response.usage, costUSD: cost, latencyMs: response.latencyMs,
                    explanation: response.output?.explanation, mode: response.output?.decision.rawValue, edits: response.output?.edits ?? [],
                    createdAt: Date())
                let reqBlob = response.rawRequest.flatMap { try? store.blobs.put($0) }
                let resBlob = response.rawResponse.flatMap { try? store.blobs.put($0) }
                try? store.insertAttempt(AttemptRecord(info: info, toolUseId: t.decisionId, sessionId: session.id, requestBlob: reqBlob, responseBlob: resBlob))

                switch status {
                case .succeeded:
                    guard let newSegments else { break }
                    let replacement: [UInt8]
                    do {
                        replacement = try t.buildReplacement(newSegments)
                    } catch {
                        // E.g. an edited tool input that is no longer valid JSON: retry once with the reason.
                        lastError = "could not build replacement content: \(error)"
                        if attempt == 0, Date().timeIntervalSince(started) < budget / 2 {
                            request.feedback = lastError
                            continue
                        }
                        break
                    }
                    guard let blob = try? store.blobs.put(replacement) else {
                        lastError = "could not store replacement content"
                        break
                    }
                    if let key = treatmentKey { try? store.storeTreatment(key: key, replacementBlob: blob, attemptId: attemptId) }
                    let explanation = response.output?.explanation ?? "rewritten"
                    // Review mode: Claude waits while the user approves or rejects the rewrite. Not for
                    // trials (nobody is there to answer) or tool inputs (Claude Code already asks).
                    if app.defaults.review, session.trialId == nil, t.stage != .input {
                        let verdict = await requestReview(t, session: session, original: segments, proposed: newSegments, explanation: explanation,
                                                          rules: rewriteRules.map(\.name), timeout: app.defaults.reviewTimeoutSeconds,
                                                          // Claude Code stops a hook after 180 s: answer well before that.
                                                          deadline: session.via == .hook ? started.addingTimeInterval(Self.hookReviewDeadline) : nil)
                        if verdict != .approved {
                            let why = verdict == .rejected ? "rewrite rejected in review" : "no review in time"
                            return redaction != nil ? recordRedacted(why) : record(.unchanged, "not rewritten: \(why)", refs: app.refs, instructions: instructionTexts)
                        }
                    }
                    return record(.rewritten, redaction.map { "\($0.summary); \(explanation)" } ?? explanation, replacement: blob, refs: app.refs,
                                  instructions: instructionTexts, treatmentKey: treatmentKey)
                case .unchanged:
                    if redaction != nil { return recordRedacted("the rewrite agent made no further changes") }
                    return record(.unchanged, "rewrite agent left the content unchanged: \(response.output?.explanation ?? "")", refs: app.refs, instructions: instructionTexts)
                case .invalid:
                    lastError = error ?? "invalid rewrite output"
                    if attempt == 0, Date().timeIntervalSince(started) < budget / 2 {
                        request.feedback = lastError
                        continue
                    }
                case .refused, .timedOut, .failed, .skipped:
                    lastError = error ?? status.rawValue
                }
                break
            }
            if redaction != nil {
                try? store.addFlag(sessionId: session.id, "rewrite-failures")
                return recordRedacted("the rewrite failed (\(lastError)), so only the redaction was applied")
            }
            let policy = session.onFailure ?? app.defaults.onFailure
            try? store.addFlag(sessionId: session.id, "rewrite-failures")
            if policy == .invalidateTrial { try? store.addFlag(sessionId: session.id, "trial-invalid") }
            return record(.failed, "\(lastError) — original forwarded (\(policy.rawValue))", refs: app.refs, instructions: instructionTexts)
        }

        guard let key = treatmentKey else { return await rewriteNow() }
        await treatmentLock.lock(key)
        if let cached = try? store.treatment(key: key), store.blobs.exists(cached.replacementBlob) {
            await treatmentLock.unlock(key)
            return record(.rewritten, "frozen treatment reused", replacement: cached.replacementBlob, refs: app.refs, instructions: instructionTexts, treatmentKey: key)
        }
        let decided = await rewriteNow()
        await treatmentLock.unlock(key)
        return decided
    }

    /// How the tool is named to the rewrite agent, so it knows what it is editing.
    static func agentToolLabel(_ toolName: String, _ stage: RuleStage) -> String {
        switch stage {
        case .result: toolName
        case .page: "\(toolName) (raw page, before extraction)"
        case .input: "\(toolName) — TOOL INPUT: the JSON arguments of a call about to run, not its output. Edit values only; keep valid JSON with the same keys."
        }
    }

    /// Builds the replacement `content` JSON: the original content bytes with only the text
    /// string values swapped, so every other byte (images, cache_control, …) is preserved.
    static func replacementBytes(body: [UInt8], content: JSONNode, segments: [JSONNode], newTexts: [String]) throws -> [UInt8] {
        precondition(segments.count == newTexts.count)
        let base = content.range.lowerBound
        let original = Array(body[content.range])
        var reps: [(range: Range<Int>, bytes: [UInt8])] = []
        for (node, text) in zip(segments, newTexts) {
            let decoded = try JSONIndex.decodeString(body, node)
            if decoded == text { continue }
            reps.append(((node.range.lowerBound - base)..<(node.range.upperBound - base), JSONEncoding.string(text)))
        }
        return try JSONSplice.apply(original, reps)
    }
}
