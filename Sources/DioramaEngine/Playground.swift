import DioramaCore
import DioramaJSON
import Foundation

extension DecisionEngine {
    /// Tries `rules` on content without a session (the rule playground). Explains which rules
    /// match; with `rewrite`, calls the rewrite agent once (plus one retry on invalid edits),
    /// exactly as a session would, but records nothing.
    public func playground(
        rules: [Rule], defaults: ProfileDefaults, toolName: String, toolInputJSON: String?, segments: [String], isError: Bool = false,
        stage: RuleStage, rewrite: Bool, spendKind: String = "playground", profileId: String? = nil, sampleId: String? = nil,
        modelOverride: String? = nil
    ) async -> PlaygroundResult {
        let text = segments.joined(separator: "\n\n")
        let input = toolInputJSON.flatMap { try? JSONValue.parse($0) } ?? .object([:])
        let ctx = MatchContext(toolName: toolName, toolInput: input, text: text, requestClass: "main", isError: isError, stage: stage, sampleId: sampleId)
        var checks = rules.map { r -> RuleCheck in
            let why = RuleMatcher.mismatch(r, ctx)
            return RuleCheck(ruleId: r.id, name: r.name.isEmpty ? "Untitled rule" : r.name, matches: why == nil, reason: why ?? "matches")
        }
        // Pasted text has no tool result id to sample by: say how sampling will work.
        if sampleId == nil {
            for (i, r) in rules.enumerated() where checks[i].matches {
                if let share = r.match.sample, share < 1 { checks[i].reason = "matches; in a session it applies to \(RuleMatcher.percent(share)) of such tool results" }
            }
        }
        let matched = rules.filter { RuleMatcher.matches($0, ctx) }
        var rewriteRules = matched.filter { !$0.isRedaction }
        var model = rewriteRules.isEmpty ? nil : (rewriteRules.last(where: { $0.model != nil })?.model ?? defaults.model)
        var result = PlaygroundResult(toolName: toolName, toolInput: toolInputJSON, stage: stage, originalText: text, checks: checks, model: model)
        // Classifier questions cost a call, so the free check only says they're pending.
        for (i, r) in rules.enumerated() where r.match.classifier != nil && result.checks[i].matches && !rewrite {
            result.checks[i].reason = "matches the conditions; its classifier question runs when you run the rewrite"
        }

        // Redaction is local and free, so the check shows it right away; the agent then sees the redacted text.
        var segments = segments
        var redaction: Redactor.Result?
        let specs = matched.compactMap(\.redact)
        if !specs.isEmpty {
            let r = Redactor.apply(specs, to: segments)
            if r.total > 0 {
                redaction = r
                segments = r.texts
                result.rewrite = PlaygroundRewrite(status: .succeeded, replacementText: segments.joined(separator: "\n\n"), explanation: r.summary,
                                                   edits: [], error: nil, model: "local redaction", costUSD: 0, latencyMs: 0)
            } else if rewriteRules.isEmpty {
                result.note = "The redaction rules found nothing to mask here."
            }
        }
        guard rewrite else { return result }
        if rewriteRules.contains(where: { $0.match.classifier != nil }) {
            var kept: [Rule] = []
            var spent = 0.0
            for r in rewriteRules {
                guard let c = r.match.classifier else {
                    kept.append(r)
                    continue
                }
                let v = await classify(c, rule: r, toolName: toolName, toolInput: toolInputJSON ?? "{}", content: segments.joined(separator: "\n\n"),
                                       defaults: defaults, decisionId: nil, sessionId: nil)
                spent += v.usage.flatMap { Pricing.cost(model: v.modelServed ?? (c.model ?? defaults.model), usage: $0) } ?? 0
                if v.answer == true { kept.append(r) }
                if let i = rules.firstIndex(where: { $0.id == r.id }) {
                    result.checks[i].matches = v.answer == true
                    result.checks[i].reason = "classifier: " + (v.answer.map { $0 ? "yes" : "no" } ?? "failed (\(v.error ?? "unknown error"))") + (v.reason.map { " — \($0)" } ?? "")
                }
            }
            store.recordSpend(kind: spendKind, profileId: profileId, costUSD: spent)
            rewriteRules = kept
            model = kept.isEmpty ? nil : (kept.last(where: { $0.model != nil })?.model ?? defaults.model)
            result.model = model
        }
        if let modelOverride, model != nil { model = modelOverride }
        guard let model else {
            if matched.isEmpty { result.note = "No rule matches this content, so a session would forward it unchanged." }
            else if !matched.contains(where: \.isRedaction) || redaction == nil { result.note = "The classifier didn't say yes, so a session would leave this unchanged." }
            return result
        }
        guard !segments.isEmpty, !text.isEmpty else {
            result.note = "There is no text to rewrite."
            return result
        }
        guard text.count <= defaults.maxInputChars else {
            result.note = "The content is longer than the profile's limit (\(defaults.maxInputChars) characters); a session would forward it unchanged."
            return result
        }
        var request = RewriteRequest(
            toolName: Self.agentToolLabel(toolName, stage), toolInput: toolInputJSON ?? "{}", segments: segments,
            instructions: rewriteRules.map { RuleInstruction(name: $0.name, text: $0.instructions) }, taskContext: nil, model: model,
            effort: rewriteRules.last(where: { $0.effort != nil })?.effort ?? defaults.effort, maxOutputTokens: defaults.maxOutputTokens,
            timeout: defaults.timeoutSeconds)
        let provider = providerFor(model)
        var latency = 0.0
        var cost: Double?
        for attempt in 0..<2 {
            let response = await provider.rewrite(request)
            latency += response.latencyMs
            if let c = response.usage.flatMap({ Pricing.cost(model: response.modelServed ?? model, usage: $0) }) { cost = (cost ?? 0) + c }
            var status = response.status
            var error = response.error
            var replacement: String?
            if let output = response.output, status == .succeeded || status == .unchanged {
                switch EditApplication.apply(output, to: segments) {
                case .success(let s):
                    if s == segments { status = .unchanged } else { replacement = s.joined(separator: "\n\n") }
                case .failure(let e):
                    status = .invalid
                    error = e.description
                }
            }
            if status == .invalid, attempt == 0 {
                request.feedback = error
                continue
            }
            // No attempt record is written, so the budget ledger carries this spending.
            store.recordSpend(kind: spendKind, profileId: profileId, costUSD: cost ?? 0)
            if let r = redaction, status != .succeeded {
                // The redaction stands even when the agent changes nothing more (or fails).
                replacement = segments.joined(separator: "\n\n")
                error = status == .unchanged ? nil : error
                status = .succeeded
                result.rewrite = PlaygroundRewrite(
                    status: status, replacementText: replacement, explanation: r.summary + "; the rewrite agent made no further changes" + (error.map { " (\($0))" } ?? ""),
                    edits: [], error: nil, model: response.modelServed ?? model, costUSD: cost, latencyMs: latency)
                break
            }
            let explanation = response.output?.explanation
            result.rewrite = PlaygroundRewrite(
                status: status, replacementText: replacement, explanation: redaction.map { r in explanation.map { "\(r.summary); \($0)" } ?? r.summary } ?? explanation,
                edits: response.output?.edits ?? [], error: error, model: response.modelServed ?? model, costUSD: cost, latencyMs: latency)
            break
        }
        return result
    }
}
