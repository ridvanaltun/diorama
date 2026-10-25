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
    let providerFor: @Sendable () -> RewriteProvider
    let inflight = Inflight()
    let anomalies = AnomalyMemory()

    public init(store: Store, provider: @escaping @Sendable () -> RewriteProvider) {
        self.store = store
        self.providerFor = provider
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
                        let d = await self.inflight.decision(for: p.result.toolUseId) {
                            await self.decide(p.result, original: p.original, hash: p.hash, scan: scan, body: body, session: session, exchangeId: exchangeId, requestClass: requestClass)
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

    func decide(
        _ tr: ScannedToolResult, original: [UInt8], hash: String, scan: ScannedRequest, body: [UInt8], session: SessionRecord,
        exchangeId: Int64, requestClass: String?
    ) async -> DecisionRecord {
        // A concurrent request may already have decided this id: the first decision wins.
        if let existing = try? store.decision(toolUseId: tr.toolUseId) { return existing }
        let toolUse = scan.toolUses[tr.toolUseId]
        let originalBlob = (try? store.blobs.put(original)) ?? hash
        let segments: [String] = tr.textSegments.compactMap { try? JSONIndex.decodeString(body, $0) }
        func record(_ outcome: DecisionOutcome, _ reason: String, replacement: String? = nil, refs: [RuleRef] = [], instructions: [String] = [], treatmentKey: String? = nil) -> DecisionRecord {
            let d = DecisionRecord(
                toolUseId: tr.toolUseId, sessionId: session.id, exchangeId: exchangeId, toolName: toolUse?.name, toolInput: toolUse?.inputJSON,
                isError: tr.isError, originalHash: hash, originalBlob: originalBlob, outcome: outcome, reason: reason,
                replacementBlob: replacement, rules: refs, instructions: instructions, treatmentKey: treatmentKey)
            // Persisted before the request is forwarded (FR-19). If persistence fails we must not
            // rewrite, because the rewrite could not be replayed.
            guard let saved = try? store.insertDecision(d) else {
                store.addEvent(sessionId: session.id, kind: .anomaly, message: "Could not persist decision for \(tr.toolUseId); forwarded unchanged", refId: tr.toolUseId)
                var fallback = d
                fallback.outcome = .failed
                fallback.replacementBlob = nil
                fallback.reason = "decision could not be persisted"
                return fallback
            }
            if saved.outcome == .rewritten || saved.outcome == .failed {
                store.addEvent(sessionId: session.id, kind: saved.outcome == .failed ? .rewriteFailed : .decisionMade,
                               message: "\(saved.toolName ?? "tool") result \(saved.outcome.rawValue): \(saved.reason)", refId: saved.toolUseId)
            } else {
                store.addEvent(sessionId: session.id, kind: .decisionMade, message: "\(saved.toolName ?? "tool") result unchanged: \(saved.reason)", refId: saved.toolUseId)
            }
            return saved
        }

        guard let toolUse else { return record(.unchanged, "no matching tool_use block in the request") }
        guard !segments.isEmpty else { return record(.unchanged, "tool result has no text content") }
        let inputValue = (try? JSONValue.parse(toolUse.inputJSON)) ?? .object([:])
        let text = segments.joined(separator: "\n\n")
        let ctx = MatchContext(toolName: toolUse.name, toolInput: inputValue, text: text, requestClass: requestClass, isError: tr.isError)
        let app = applicableRules(session: session, ctx: ctx)
        if app.rules.isEmpty {
            let hasRules = !(session.profileVersion?.profile.rules.isEmpty ?? true) || session.prompt != nil
            return record(.unchanged, hasRules ? "no rule matched" : "no rules configured")
        }
        let instructions = app.rules.map { RuleInstruction(name: $0.name, text: $0.instructions) }
        let instructionTexts = instructions.map { "[\($0.name)] \($0.text)" }
        if text.count > app.defaults.maxInputChars {
            return record(.unchanged, "tool result too large to rewrite (\(text.count) > \(app.defaults.maxInputChars) characters)", refs: app.refs, instructions: instructionTexts)
        }

        // Frozen experiment treatment: identical inputs reuse the stored rewrite (decision D11).
        var treatmentKey: String?
        if let scope = session.treatmentScope {
            let key = Hashing.sha256Hex([scope, RewritePrompt.version, app.refs.map(\.ruleHash).joined(separator: ","), toolUse.name, inputValue.canonicalString, hash].joined(separator: "\u{1F}"))
            treatmentKey = key
            if let cached = try? store.treatment(key: key), store.blobs.exists(cached.replacementBlob) {
                return record(.rewritten, "frozen treatment reused", replacement: cached.replacementBlob, refs: app.refs, instructions: instructionTexts, treatmentKey: key)
            }
        }

        let model = app.rules.last(where: { $0.model != nil })?.model ?? app.defaults.model
        let effort = app.rules.last(where: { $0.effort != nil })?.effort ?? app.defaults.effort
        let wantsTask = app.rules.contains { $0.context == .task }
        var request = RewriteRequest(
            toolName: toolUse.name, toolInput: toolUse.inputJSON, segments: segments, instructions: instructions,
            taskContext: wantsTask ? scan.taskText : nil, model: model, effort: effort,
            maxOutputTokens: app.defaults.maxOutputTokens, timeout: app.defaults.timeoutSeconds)

        let provider = providerFor()
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
            try? store.insertAttempt(AttemptRecord(info: info, toolUseId: tr.toolUseId, sessionId: session.id, requestBlob: reqBlob, responseBlob: resBlob))

            switch status {
            case .succeeded:
                guard let newSegments else { break }
                guard let replacement = try? Self.replacementBytes(body: body, content: tr.content!, segments: tr.textSegments, newTexts: newSegments),
                      let blob = try? store.blobs.put(replacement)
                else {
                    lastError = "could not build replacement content"
                    break
                }
                if let key = treatmentKey { try? store.storeTreatment(key: key, replacementBlob: blob, attemptId: attemptId) }
                return record(.rewritten, response.output?.explanation ?? "rewritten", replacement: blob, refs: app.refs, instructions: instructionTexts, treatmentKey: treatmentKey)
            case .unchanged:
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
        let policy = session.onFailure ?? app.defaults.onFailure
        try? store.addFlag(sessionId: session.id, "rewrite-failures")
        if policy == .invalidateTrial { try? store.addFlag(sessionId: session.id, "trial-invalid") }
        return record(.failed, "\(lastError) — original forwarded (\(policy.rawValue))", refs: app.refs, instructions: instructionTexts)
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
