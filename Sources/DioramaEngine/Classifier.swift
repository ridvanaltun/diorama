import DioramaCore
import DioramaJSON
import Foundation

/// A yes/no question about one tool result, answered by a cheap model (content-aware matching).
public struct ClassifyRequest: Sendable {
    public var toolName: String
    public var toolInput: String
    public var content: String
    public var question: String
    public var model: String
    public var timeout: TimeInterval

    public init(toolName: String, toolInput: String, content: String, question: String, model: String, timeout: TimeInterval) {
        self.toolName = toolName
        self.toolInput = toolInput
        self.content = content
        self.question = question
        self.model = model
        self.timeout = timeout
    }
}

public struct ClassifyResponse: Sendable {
    /// nil when the call failed (callers treat that as "no": nothing is rewritten on a guess).
    public var answer: Bool?
    public var reason: String?
    public var error: String?
    public var modelServed: String?
    public var usage: TokenUsage?
    public var latencyMs: Double
    public var rawRequest: String?
    public var rawResponse: String?

    public init(answer: Bool?, reason: String? = nil, error: String? = nil, modelServed: String? = nil, usage: TokenUsage? = nil, latencyMs: Double = 0,
                rawRequest: String? = nil, rawResponse: String? = nil) {
        self.answer = answer
        self.reason = reason
        self.error = error
        self.modelServed = modelServed
        self.usage = usage
        self.latencyMs = latencyMs
        self.rawRequest = rawRequest
        self.rawResponse = rawResponse
    }
}

public enum ClassifyPrompt {
    public static let version = "classify-v1"

    public static let system = """
        You classify one tool output for Diorama, a research tool that studies an AI coding agent. Answer the \
        researcher's yes/no question about the content only, using only the content shown. Answer "no" when the \
        content doesn't clearly support "yes". Give a one-sentence reason.
        """

    public static let schema: JSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "required": .array([.string("answer"), .string("reason")]),
        "properties": .object([
            "answer": .object(["type": .string("string"), "enum": .array([.string("yes"), .string("no")])]),
            "reason": .object(["type": .string("string")]),
        ]),
    ])

    public static func userMessage(_ r: ClassifyRequest) -> String {
        "<tool_name>\(r.toolName)</tool_name>\n<tool_input>\(r.toolInput)</tool_input>\n<question>\(r.question)</question>\n<content>\n\(r.content)\n</content>"
    }

    /// Reads `{answer, reason}` from the model's JSON text.
    static func decode(_ text: String) -> (Bool, String?)? {
        guard let v = try? JSONValue.parse(text), let a = v["answer"]?.stringValue, a == "yes" || a == "no" else { return nil }
        return (a == "yes", v["reason"]?.stringValue)
    }
}

extension RewriteProvider {
    public func classify(_ r: ClassifyRequest) async -> ClassifyResponse {
        ClassifyResponse(answer: nil, error: "the \(id) provider can't classify content")
    }
}

extension AnthropicRewriteProvider {
    public func classify(_ r: ClassifyRequest) async -> ClassifyResponse {
        guard let key = apiKey(), !key.isEmpty else { return ClassifyResponse(answer: nil, error: "No Anthropic API key is configured for the rewrite agent.") }
        var body: [String: JSONValue] = [
            "model": .string(r.model), "max_tokens": .number("400"), "system": .string(ClassifyPrompt.system),
            "messages": .array([.object(["role": .string("user"), "content": .string(ClassifyPrompt.userMessage(r))])]),
            "output_config": .object(["format": .object(["type": .string("json_schema"), "schema": ClassifyPrompt.schema])]),
        ]
        if Self.fallbackModels.contains(r.model) { body["fallbacks"] = .string("default") }
        let bytes = JSONValue.object(body).canonicalBytes
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        req.httpMethod = "POST"
        req.timeoutInterval = r.timeout
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("diorama/\(DioramaVersion.current)", forHTTPHeaderField: "user-agent")
        if Self.fallbackModels.contains(r.model) { req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta") }
        req.httpBody = Data(bytes)
        let start = Date()
        let requestText = String(decoding: bytes, as: UTF8.self)
        do {
            let (data, response) = try await session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(decoding: data, as: UTF8.self)
            let latency = Date().timeIntervalSince(start) * 1000
            guard status == 200 else {
                return ClassifyResponse(answer: nil, error: "HTTP \(status): \(Self.errorMessage(text))", latencyMs: latency, rawRequest: requestText, rawResponse: text)
            }
            // The Messages response shape is the same as a rewrite's; only the JSON in the text differs.
            let parsed = Self.parse(text)
            var content = ""
            if let v = try? JSONValue.parse(text), case .array(let blocks)? = v["content"] {
                for b in blocks where b["type"]?.stringValue == "text" { content += b["text"]?.stringValue ?? "" }
            }
            guard let (answer, reason) = ClassifyPrompt.decode(content) else {
                return ClassifyResponse(answer: nil, error: parsed.error ?? "the classifier's output didn't match the schema", modelServed: parsed.modelServed,
                                        usage: parsed.usage, latencyMs: latency, rawRequest: requestText, rawResponse: text)
            }
            return ClassifyResponse(answer: answer, reason: reason, modelServed: parsed.modelServed, usage: parsed.usage, latencyMs: latency, rawRequest: requestText, rawResponse: text)
        } catch {
            return ClassifyResponse(answer: nil, error: error.localizedDescription, latencyMs: Date().timeIntervalSince(start) * 1000, rawRequest: requestText)
        }
    }
}

extension OllamaRewriteProvider {
    public func classify(_ r: ClassifyRequest) async -> ClassifyResponse {
        let start = Date()
        let (request, res) = await chat(model: r.model, system: ClassifyPrompt.system, user: ClassifyPrompt.userMessage(r), schema: ClassifyPrompt.schema, timeout: r.timeout)
        let latency = Date().timeIntervalSince(start) * 1000
        guard let content = res.content, let (answer, reason) = ClassifyPrompt.decode(content) else {
            return ClassifyResponse(answer: nil, error: res.error ?? "the classifier's output didn't match the schema", modelServed: res.model, usage: res.usage,
                                    latencyMs: latency, rawRequest: request, rawResponse: res.raw)
        }
        return ClassifyResponse(answer: answer, reason: reason, modelServed: res.model, usage: res.usage, latencyMs: latency, rawRequest: request, rawResponse: res.raw)
    }
}
