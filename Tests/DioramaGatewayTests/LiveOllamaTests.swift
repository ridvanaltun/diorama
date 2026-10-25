import DioramaCore
import DioramaEngine
import Foundation
import Testing

/// Against a real local Ollama, opt in: `DIORAMA_LIVE_OLLAMA=qwen2.5:1.5b swift test --filter LiveOllama`.
/// Skipped otherwise (CI has no Ollama). Local only: nothing leaves the Mac, nothing is billed.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DIORAMA_LIVE_OLLAMA"] != nil))
struct LiveOllamaTests {
    let model = "ollama:" + (ProcessInfo.processInfo.environment["DIORAMA_LIVE_OLLAMA"] ?? "")
    let provider = OllamaRewriteProvider(baseURL: { URL(string: ProcessInfo.processInfo.environment["DIORAMA_OLLAMA_URL"] ?? DioramaSettings.defaultOllamaURL)! })

    @Test func rewritesAndTheEditApplies() async throws {
        let segments = ["Acme SDK documentation. The latest version is 2.3.0, released in May. Install it with pip install acme==2.3.0."]
        var request = RewriteRequest(
            toolName: "WebFetch", toolInput: #"{"url":"https://docs.acme.dev"}"#, segments: segments,
            instructions: [RuleInstruction(name: "Bump version", text: "Change the latest version number 2.3.0 to 2.4.0 wherever it appears. Change nothing else.")],
            taskContext: nil, model: model, effort: nil, maxOutputTokens: 16_000, timeout: 120)
        // Like a session: one retry with the reason when the edits don't apply.
        for attempt in 1...2 {
            let r = await provider.rewrite(request)
            print("LIVE attempt \(attempt): status=\(r.status) latency=\(Int(r.latencyMs))ms usage=\(String(describing: r.usage)) error=\(r.error ?? "-")")
            guard let output = r.output else { Issue.record("no output: \(r.error ?? "")"); return }
            switch EditApplication.apply(output, to: segments) {
            case .success(let applied):
                print("LIVE applied=\(applied)")
                #expect(applied[0].contains("2.4.0") && !applied[0].contains("2.3.0"))
                return
            case .failure(let e):
                print("LIVE edits didn't apply: \(e)")
                request.feedback = e.description
            }
        }
        Issue.record("the edits didn't apply after a retry")
    }

    @Test func classifies() async throws {
        let yes = await provider.classify(ClassifyRequest(toolName: "WebFetch", toolInput: "{}", content: "Pro plan: $20 per month, billed yearly.",
                                                          question: "Does this page state a price?", model: model, timeout: 60))
        let no = await provider.classify(ClassifyRequest(toolName: "WebFetch", toolInput: "{}", content: "Our team has 20 people in three offices.",
                                                         question: "Does this page state a price?", model: model, timeout: 60))
        print("LIVE classify yes=\(String(describing: yes.answer)) (\(yes.reason ?? yes.error ?? "")) no=\(String(describing: no.answer)) (\(no.reason ?? no.error ?? ""))")
        // The answers must follow the schema; whether they're right depends on the model (small ones often aren't).
        #expect(yes.answer != nil && no.answer != nil)
        print("LIVE classify correct: \(yes.answer == true && no.answer == false)")
    }
}
