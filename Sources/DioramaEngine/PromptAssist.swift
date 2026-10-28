import DioramaCore
import DioramaJSON
import Foundation

/// Writing a session prompt with AI: the user says what they want Claude to see differently,
/// and the rewrite model drafts the instructions for the rewrite agent (and the tools they
/// should apply to). Uses the rewrite agent's own key and model, never Claude Code's.
public struct PromptAssistRequest: Sendable {
    public var goal: String
    public var currentPrompt: String?
    public var tools: [String]
    public var model: String
    public var timeout: TimeInterval

    public init(goal: String, currentPrompt: String?, tools: [String], model: String, timeout: TimeInterval = 60) {
        self.goal = goal
        self.currentPrompt = currentPrompt
        self.tools = tools
        self.model = model
        self.timeout = timeout
    }
}

public struct PromptAssistResponse: Sendable {
    public var suggestion: PromptSuggestion?
    public var error: String?
    public var modelServed: String?
    public var usage: TokenUsage?
    public var latencyMs: Double

    public init(suggestion: PromptSuggestion?, error: String? = nil, modelServed: String? = nil, usage: TokenUsage? = nil, latencyMs: Double = 0) {
        self.suggestion = suggestion
        self.error = error
        self.modelServed = modelServed
        self.usage = usage
        self.latencyMs = latencyMs
    }
}

public enum PromptAssistPrompt {
    public static let system = """
        You help a researcher use Diorama, a tool for studying how an AI coding agent (Claude Code) reacts to \
        the information it receives. Diorama's rewrite agent modifies selected tool results (web pages from \
        WebFetch, search results from WebSearch, files from Read, command output from Bash, search hits from \
        Grep, MCP tool results) before Claude Code sees them, following a "session prompt".

        The researcher describes, in their own words, what they want Claude to see differently. Write the \
        session prompt: instructions addressed to the rewrite agent.

        A good session prompt:
        - says exactly what to change and where it appears (which facts, names, versions or statements);
        - asks for minimal, natural edits that keep the original format and tone, and says to change nothing else;
        - says when to leave the content unchanged (for example, pages that don't mention the subject);
        - never asks for notes, markers or disclaimers about the change;
        - is short: a few sentences, in English.

        Also choose the tools it should apply to, from: WebFetch, WebSearch, Read, Bash, Grep (and mcp__* \
        patterns if the researcher mentions MCP tools). Pick only the ones where the information would appear.

        If a current prompt is given, improve it toward the researcher's goal instead of starting over.

        Answer with JSON: {"prompt": the session prompt, "tools": [tool names], "explanation": one or two \
        sentences, in the researcher's language, on what the prompt does}.
        """

    public static let schema: JSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "required": .array([.string("prompt"), .string("tools"), .string("explanation")]),
        "properties": .object([
            "prompt": .object(["type": .string("string")]),
            "tools": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
            "explanation": .object(["type": .string("string")]),
        ]),
    ])

    public static func userMessage(_ r: PromptAssistRequest) -> String {
        var out = "<goal>\n\(r.goal)\n</goal>\n"
        if let current = r.currentPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !current.isEmpty {
            out += "<current_prompt>\n\(current)\n</current_prompt>\n"
        }
        if !r.tools.isEmpty { out += "<current_tools>\(r.tools.joined(separator: ", "))</current_tools>\n" }
        return out
    }

    /// Reads `{prompt, tools, explanation}` from the model's JSON text.
    static func decode(_ text: String) -> PromptSuggestion? {
        guard let v = try? JSONValue.parse(text), let prompt = v["prompt"]?.stringValue,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        var tools: [String] = []
        if case .array(let items)? = v["tools"] { tools = items.compactMap(\.stringValue).filter { !$0.isEmpty } }
        return PromptSuggestion(prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                                tools: tools.isEmpty ? SessionPrompt.defaultTools : tools,
                                explanation: v["explanation"]?.stringValue ?? "")
    }
}

extension RewriteProvider {
    public func assistPrompt(_ r: PromptAssistRequest) async -> PromptAssistResponse {
        PromptAssistResponse(suggestion: nil, error: "the \(id) provider can't write prompts")
    }
}

extension AnthropicRewriteProvider {
    public func assistPrompt(_ r: PromptAssistRequest) async -> PromptAssistResponse {
        guard let key = apiKey(), !key.isEmpty else {
            return PromptAssistResponse(suggestion: nil, error: "No Anthropic API key is configured for the rewrite agent. Add one in Settings.")
        }
        var body: [String: JSONValue] = [
            "model": .string(r.model), "max_tokens": .number("1200"), "system": .string(PromptAssistPrompt.system),
            "messages": .array([.object(["role": .string("user"), "content": .string(PromptAssistPrompt.userMessage(r))])]),
            "output_config": .object(["format": .object(["type": .string("json_schema"), "schema": PromptAssistPrompt.schema])]),
        ]
        if Self.fallbackModels.contains(r.model) { body["fallbacks"] = .string("default") }
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        req.httpMethod = "POST"
        req.timeoutInterval = r.timeout
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("diorama/\(DioramaVersion.current)", forHTTPHeaderField: "user-agent")
        if Self.fallbackModels.contains(r.model) { req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta") }
        req.httpBody = Data(JSONValue.object(body).canonicalBytes)
        let start = Date()
        do {
            let (data, response) = try await session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(decoding: data, as: UTF8.self)
            let latency = Date().timeIntervalSince(start) * 1000
            guard status == 200 else {
                return PromptAssistResponse(suggestion: nil, error: "HTTP \(status): \(Self.errorMessage(text))", latencyMs: latency)
            }
            let parsed = Self.parse(text)
            var content = ""
            if let v = try? JSONValue.parse(text), case .array(let blocks)? = v["content"] {
                for b in blocks where b["type"]?.stringValue == "text" { content += b["text"]?.stringValue ?? "" }
            }
            let suggestion = PromptAssistPrompt.decode(content)
            return PromptAssistResponse(suggestion: suggestion, error: suggestion == nil ? (parsed.error ?? "the answer didn't match the expected format") : nil,
                                        modelServed: parsed.modelServed, usage: parsed.usage, latencyMs: latency)
        } catch {
            return PromptAssistResponse(suggestion: nil, error: error.localizedDescription, latencyMs: Date().timeIntervalSince(start) * 1000)
        }
    }
}

extension OllamaRewriteProvider {
    public func assistPrompt(_ r: PromptAssistRequest) async -> PromptAssistResponse {
        let start = Date()
        let (_, res) = await chat(model: r.model, system: PromptAssistPrompt.system, user: PromptAssistPrompt.userMessage(r),
                                  schema: PromptAssistPrompt.schema, timeout: r.timeout, maxOutput: 1200)
        let suggestion = res.content.flatMap(PromptAssistPrompt.decode)
        return PromptAssistResponse(suggestion: suggestion, error: suggestion == nil ? (res.error ?? "the answer didn't match the expected format") : nil,
                                    modelServed: res.model, usage: res.usage, latencyMs: Date().timeIntervalSince(start) * 1000)
    }
}

extension DecisionEngine {
    /// Drafts a session prompt with the default rewrite model, within the daily budget; its cost
    /// is recorded like the playground's.
    public func assistPrompt(goal: String, currentPrompt: String?, tools: [String]) async -> PromptAssistResult {
        let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = store.settings().defaultModel
        guard !goal.isEmpty else { return PromptAssistResult(error: "Describe what Claude should see differently.", model: model) }
        if let block = budgetBlock(profileId: nil, profileBudget: nil) { return PromptAssistResult(error: "Not sent: \(block).", model: model) }
        let response = await providerFor(model).assistPrompt(PromptAssistRequest(goal: goal, currentPrompt: currentPrompt, tools: tools, model: model))
        let cost = response.usage.flatMap { Pricing.cost(model: response.modelServed ?? model, usage: $0) }
        if let cost, cost > 0 { store.recordSpend(kind: "prompt-assist", profileId: nil, costUSD: cost) }
        return PromptAssistResult(suggestion: response.suggestion, error: response.error, model: response.modelServed ?? model, costUSD: cost)
    }
}
