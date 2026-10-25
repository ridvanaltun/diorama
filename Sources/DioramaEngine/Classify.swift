import DioramaCore
import DioramaStore
import Foundation

extension DecisionEngine {
    /// Asks a rule's classifier question about the content and records the call as an attempt
    /// (mode "classify"), so it shows in the audit trail and counts toward spending.
    func classify(_ c: RuleClassifier, rule: Rule, toolName: String, toolInput: String, content: String, defaults: ProfileDefaults,
                  decisionId: String?, sessionId: String?) async -> ClassifyResponse {
        let model = c.model ?? defaults.model
        let provider = providerFor(model)
        let request = ClassifyRequest(toolName: toolName, toolInput: toolInput, content: String(content.prefix(defaults.maxInputChars)),
                                      question: c.question, model: model, timeout: defaults.timeoutSeconds)
        let v = await provider.classify(request)
        let cost = v.usage.flatMap { Pricing.cost(model: v.modelServed ?? model, usage: $0) }
        if let decisionId {
            let info = RewriteAttemptInfo(
                id: Hashing.newId(prefix: "att"), provider: provider.id, modelRequested: model, modelServed: v.modelServed, promptVersion: ClassifyPrompt.version,
                status: v.answer == nil ? .failed : (v.answer! ? .succeeded : .unchanged), error: v.error, usage: v.usage, costUSD: cost, latencyMs: v.latencyMs,
                explanation: "Classifier (\(rule.name)): \(v.answer.map { $0 ? "yes" : "no" } ?? "failed")" + (v.reason.map { " — \($0)" } ?? ""),
                mode: "classify", edits: [], createdAt: Date())
            let reqBlob = v.rawRequest.flatMap { try? store.blobs.put($0) }
            let resBlob = v.rawResponse.flatMap { try? store.blobs.put($0) }
            try? store.insertAttempt(AttemptRecord(info: info, toolUseId: decisionId, sessionId: sessionId, requestBlob: reqBlob, responseBlob: resBlob))
        }
        return v
    }
}
