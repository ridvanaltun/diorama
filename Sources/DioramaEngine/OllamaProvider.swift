import DioramaCore
import DioramaJSON
import Foundation

/// Local models through Ollama (`/api/chat` with a JSON-schema `format`). Selected by model ids
/// of the form `ollama:<model>`, e.g. `ollama:llama3.1`. Nothing leaves the Mac; cost is 0.
public struct OllamaRewriteProvider: RewriteProvider, JudgeProvider {
    public let id = "ollama"
    public static let prefix = "ollama:"
    let baseURL: @Sendable () -> URL

    public init(baseURL: @escaping @Sendable () -> URL) { self.baseURL = baseURL }

    public static func isOllama(_ model: String) -> Bool { model.hasPrefix(prefix) }

    static func localModel(_ model: String) -> String { String(model.dropFirst(prefix.count)) }

    struct ChatResult {
        var content: String?
        var model: String?
        var usage: TokenUsage?
        var raw: String?
        var error: String?
        var timedOut = false
    }

    /// Ollama's default context is small (4k tokens on Macs with under 24 GB of memory) and longer
    /// prompts are cut silently, so every request asks for a context that fits it.
    public static let minContext = 8192, maxContext = 65536

    /// Tokens to ask for (a conservative 3 characters per token, plus room for the answer), or nil
    /// when even `maxContext` is too small.
    public static func contextSize(promptChars: Int, maxOutput: Int) -> Int? {
        let needed = promptChars / 3 + 512 + min(maxOutput, 8192)
        guard needed <= maxContext else { return nil }
        return max(minContext, (needed + 2047) / 2048 * 2048)
    }

    func chat(model: String, system: String, user: String, schema: JSONValue, timeout: TimeInterval, maxOutput: Int = 1024) async -> (request: String, result: ChatResult) {
        guard let context = Self.contextSize(promptChars: system.count + user.count, maxOutput: maxOutput) else {
            let tokens = (system.count + user.count) / 3
            return ("", ChatResult(error: "too long for a local model: about \(tokens) tokens, more than the \(Self.maxContext)-token context Diorama asks Ollama for. Lower the rule's max input, or use a Claude model for this rule"))
        }
        let body: JSONValue = .object([
            "model": .string(Self.localModel(model)),
            "stream": .bool(false),
            "format": schema,
            // num_predict: small models can ramble without end (seen with qwen2.5:1.5b at temperature 0).
            "options": .object(["temperature": .number("0"), "num_ctx": .number(String(context)), "num_predict": .number(String(maxOutput))]),
            "messages": .array([
                .object(["role": .string("system"), "content": .string(system)]),
                .object(["role": .string("user"), "content": .string(user)]),
            ]),
        ])
        let bytes = body.canonicalBytes
        var req = URLRequest(url: baseURL().appendingPathComponent("api/chat"))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = Data(bytes)
        let requestText = String(decoding: bytes, as: UTF8.self)
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(decoding: data, as: UTF8.self)
            guard status == 200, let v = try? JSONValue.parse(text) else {
                let msg = (try? JSONValue.parse(text))?["error"]?.stringValue ?? String(text.prefix(200))
                return (requestText, ChatResult(raw: text, error: "Ollama HTTP \(status): \(msg)"))
            }
            func n(_ k: String) -> Int { v[k].flatMap { if case .number(let s) = $0 { return Int(s) } else { return nil } } ?? 0 }
            return (requestText, ChatResult(
                content: v["message"]?["content"]?.stringValue, model: v["model"].flatMap(\.stringValue).map { Self.prefix + $0 },
                usage: TokenUsage(inputTokens: n("prompt_eval_count"), outputTokens: n("eval_count")), raw: text))
        } catch let e as URLError where e.code == .timedOut {
            return (requestText, ChatResult(error: "Ollama timed out after \(Int(timeout))s (the first request after starting includes loading the model, and large models or a busy Mac are slower; raise the rule's timeout if this repeats)", timedOut: true))
        } catch let e as URLError where e.code == .cannotConnectToHost {
            return (requestText, ChatResult(error: "Ollama is not running at \(baseURL().absoluteString) (start it with `ollama serve`)"))
        } catch {
            return (requestText, ChatResult(error: error.localizedDescription))
        }
    }

    public func rewrite(_ r: RewriteRequest) async -> RewriteResponse {
        let start = Date()
        let (request, res) = await chat(model: r.model, system: RewritePrompt.system, user: RewritePrompt.userMessage(r), schema: RewritePrompt.schema, timeout: r.timeout,
                                        maxOutput: Self.rewriteOutputLimit(r))
        let latency = Date().timeIntervalSince(start) * 1000
        guard let content = res.content else {
            return RewriteResponse(status: res.timedOut ? .timedOut : .failed, error: res.error, modelServed: res.model, usage: res.usage, rawRequest: request, rawResponse: res.raw, latencyMs: latency)
        }
        guard let output = try? JSONDecoder().decode(RewriteOutput.self, from: Data(content.utf8)) else {
            return RewriteResponse(status: .invalid, error: "The local model's output did not match the expected JSON schema.", modelServed: res.model, usage: res.usage, rawRequest: request, rawResponse: res.raw, latencyMs: latency)
        }
        return RewriteResponse(status: output.decision == .unchanged ? .unchanged : .succeeded, output: output, modelServed: res.model, usage: res.usage, rawRequest: request, rawResponse: res.raw, latencyMs: latency)
    }

    /// Room for a full replacement of the content (about 1.5× its tokens) plus the JSON around
    /// it, never more than the rule allows.
    public static func rewriteOutputLimit(_ r: RewriteRequest) -> Int {
        min(r.maxOutputTokens, r.segments.reduce(0) { $0 + $1.count } / 2 + 768)
    }

    public func judge(_ r: JudgeRequest) async -> JudgeResult {
        let (_, res) = await chat(model: r.model, system: JudgePrompt.system, user: JudgePrompt.userMessage(r), schema: JudgePrompt.schema, timeout: r.timeout, maxOutput: 600)
        guard let content = res.content, let v = try? JSONValue.parse(content), let verdict = v["verdict"]?.stringValue,
              ["adopted", "not_adopted", "unclear"].contains(verdict)
        else { return JudgeResult(verdict: nil, rationale: nil, modelServed: res.model, usage: res.usage, costUSD: 0, error: res.error ?? "judge output did not match the schema") }
        return JudgeResult(verdict: verdict, rationale: v["rationale"]?.stringValue, modelServed: res.model, usage: res.usage, costUSD: 0)
    }
}

/// Routes judge calls by model, like rewrite providers.
public struct RoutingJudge: JudgeProvider {
    let anthropic: JudgeProvider
    let ollama: JudgeProvider
    public init(anthropic: JudgeProvider, ollama: JudgeProvider) {
        self.anthropic = anthropic
        self.ollama = ollama
    }
    public func judge(_ request: JudgeRequest) async -> JudgeResult {
        OllamaRewriteProvider.isOllama(request.model) ? await ollama.judge(request) : await anthropic.judge(request)
    }
}
