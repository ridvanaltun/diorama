import DioramaCore
import DioramaJSON
import Foundation

extension DecisionEngine {
    /// Tries `rules` on content without a session (the rule playground). Explains which rules
    /// match; with `rewrite`, calls the rewrite agent once (plus one retry on invalid edits),
    /// exactly as a session would, but records nothing.
    public func playground(
        rules: [Rule], defaults: ProfileDefaults, toolName: String, toolInputJSON: String?, segments: [String], isError: Bool = false,
        stage: RuleStage, rewrite: Bool, spendKind: String = "playground", profileId: String? = nil
    ) async -> PlaygroundResult {
        let text = segments.joined(separator: "\n\n")
        let input = toolInputJSON.flatMap { try? JSONValue.parse($0) } ?? .object([:])
        let ctx = MatchContext(toolName: toolName, toolInput: input, text: text, requestClass: "main", isError: isError, stage: stage)
        let checks = rules.map { r -> RuleCheck in
            let why = RuleMatcher.mismatch(r, ctx)
            return RuleCheck(ruleId: r.id, name: r.name.isEmpty ? "Untitled rule" : r.name, matches: why == nil, reason: why ?? "matches")
        }
        let matched = rules.filter { RuleMatcher.matches($0, ctx) }
        let rewriteRules = matched.filter { !$0.isRedaction }
        let model = rewriteRules.isEmpty ? nil : (rewriteRules.last(where: { $0.model != nil })?.model ?? defaults.model)
        var result = PlaygroundResult(toolName: toolName, toolInput: toolInputJSON, stage: stage, originalText: text, checks: checks, model: model)

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
        guard let model else {
            if matched.isEmpty { result.note = "No rule matches this content, so a session would forward it unchanged." }
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
            toolName: stage == .page ? "\(toolName) (raw page, before extraction)" : toolName, toolInput: toolInputJSON ?? "{}", segments: segments,
            instructions: matched.map { RuleInstruction(name: $0.name, text: $0.instructions) }, taskContext: nil, model: model,
            effort: matched.last(where: { $0.effort != nil })?.effort ?? defaults.effort, maxOutputTokens: defaults.maxOutputTokens,
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
