import Foundation

/// How an experiment trial runs OpenCode (`opencode run`) instead of `claude -p`, from the same
/// `ClaudeRunOptions`:
///
/// - `model` becomes `-m anthropic/<model>`; only Anthropic models reach the gateway, so it's required.
/// - `allowedTools` and `disallowedTools` become OpenCode permission rules (deny everything, then
///   allow the listed tools; disallowed ones are denied last). Tool names of either agent work.
/// - `maxTurns` becomes the `build` agent's `steps`.
/// - `isolateConfiguration` gives each trial an empty `XDG_CONFIG_HOME`, so the user's global
///   OpenCode configuration, plugins and MCP servers don't apply; credentials (in OpenCode's data
///   folder) still do. The project's own configuration applies, as with Claude Code.
/// - `permissionMode` and `maxBudgetUSD` have no OpenCode equivalent and are ignored.
public enum OpenCodeTrial {
    public static let defaultAgent = "build"
    /// OpenCode 2's built-in tools (others come from MCP servers or plugins).
    public static let builtInTools: Set<String> = [
        "edit", "glob", "grep", "question", "read", "shell", "bash", "skill", "subagent", "webfetch", "websearch", "write", "execute",
    ]

    public static func problems(_ o: ClaudeRunOptions) -> [String] {
        guard let model = o.model?.trimmingCharacters(in: .whitespaces), !model.isEmpty else {
            return ["OpenCode experiments need a model, and an Anthropic one: only those are routed through Diorama (for example claude-sonnet-4-5)"]
        }
        if model.contains("/"), !model.hasPrefix("anthropic/") {
            return ["OpenCode trials can only use Anthropic models (anthropic/…): other providers bypass Diorama, so nothing would be steered or recorded"]
        }
        return []
    }

    /// `claude-sonnet-4-5` or `anthropic/claude-sonnet-4-5` → `anthropic/claude-sonnet-4-5`.
    public static func modelReference(_ model: String) -> String {
        model.hasPrefix("anthropic/") ? model : "anthropic/" + model
    }

    /// The model id requests carry (for pricing and estimates): without the provider prefix.
    public static func modelId(_ model: String?) -> String? {
        model.map { $0.hasPrefix("anthropic/") ? String($0.dropFirst("anthropic/".count)) : $0 }
    }

    /// The command line after the executable. The task goes on stdin.
    public static func arguments(_ o: ClaudeRunOptions) -> [String] {
        var args = ["run", "--standalone", "--auto", "--format", "json"]
        if let m = o.model, !m.isEmpty { args += ["-m", modelReference(m)] }
        return args + o.extraArguments
    }

    /// The trial's inline configuration: the session's (gateway routing and lockdown) over the
    /// trial's tool permissions and step limit. Permissions concatenate, so lockdown's denials come
    /// last and win.
    public static func configuration(_ o: ClaudeRunOptions, session: [String: Any]) -> [String: Any] {
        var trial: [String: Any] = [:]
        let rules = permissions(allowed: o.allowedTools, disallowed: o.disallowedTools)
        if !rules.isEmpty { trial["permissions"] = rules }
        if let steps = o.maxTurns, steps > 0 { trial["agents"] = [defaultAgent: ["steps": steps]] }
        return OpenCodeLaunch.merge(trial, session)
    }

    /// OpenCode permission rules for Claude-Code-style tool lists (`WebFetch`, `Bash(git log:*)`,
    /// `mcp__docs__search`, or OpenCode names such as `webfetch`).
    public static func permissions(allowed: [String], disallowed: [String]) -> [[String: String]] {
        var rules: [[String: String]] = []
        let allow = allowed.compactMap(rule)
        if !allow.isEmpty {
            rules.append(["action": "*", "resource": "*", "effect": "deny"])
            rules += allow.map { ["action": $0.action, "resource": $0.resource, "effect": "allow"] }
        }
        rules += disallowed.compactMap(rule).map { ["action": $0.action, "resource": $0.resource, "effect": "deny"] }
        return rules
    }

    /// One tool spec as an OpenCode permission action and resource.
    static func rule(_ spec: String) -> (action: String, resource: String)? {
        let s = spec.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        var name = s, pattern: String?
        if let open = s.firstIndex(of: "("), s.hasSuffix(")") {
            name = String(s[..<open])
            pattern = String(s[s.index(after: open)..<s.index(before: s.endIndex)])
        }
        let action = actionName(name)
        guard let pattern, !pattern.isEmpty, pattern != "*" else { return (action, "*") }
        // Claude Code's `Bash(git log:*)` prefix form → OpenCode's `git log *`.
        if action == "shell", pattern.hasSuffix(":*") { return (action, String(pattern.dropLast(2)) + " *") }
        return (action, pattern)
    }

    /// OpenCode's permission action for a tool name of either agent.
    static func actionName(_ name: String) -> String {
        if name == "*" { return "*" }
        if name.hasPrefix("mcp__") {
            // mcp__server__tool → server_tool (OpenCode's `<server>_<tool>`).
            return name.dropFirst(5).replacingOccurrences(of: "__", with: "_")
        }
        if ToolNames.isShell(name) { return "shell" }
        return ToolNames.allNames(name).first { $0.first?.isLowercase == true } ?? name
    }
}

/// What a trial's `opencode run --format json` output says: tool calls, the final answer, turns
/// and errors. Usage and cost come from the gateway's records instead, because OpenCode doesn't
/// print the last step's usage.
public struct OpenCodeOutput: Sendable, Hashable {
    public var finalOutput = ""
    public var assistantTexts: [String] = []
    public var toolSequence: [ToolCall] = []
    /// Model calls: distinct assistant messages seen in any event (retries of one message count
    /// once; OpenCode doesn't always print a message's `step_start`).
    public var numTurns = 0
    public var error: String?
    public var sessionId: String?

    public struct ToolCall: Sendable, Hashable {
        public var name: String
        public var input: String

        public init(name: String, input: String) {
            self.name = name
            self.input = input
        }
    }

    public var toolCalls: [String: Int] { toolSequence.reduce(into: [:]) { $0[$1.name, default: 0] += 1 } }

    public static func parse(_ text: String) -> OpenCodeOutput {
        var out = OpenCodeOutput()
        var messages = Set<String>()
        var textByMessage: [(id: String, text: String)] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            if out.sessionId == nil { out.sessionId = obj["sessionID"] as? String }
            let part = obj["part"] as? [String: Any] ?? [:]
            if let id = part["messageID"] as? String { messages.insert(id) }
            switch obj["type"] as? String {
            case "tool_use":
                let input = (part["state"] as? [String: Any])?["input"] ?? [String: Any]()
                let data = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])) ?? Data("{}".utf8)
                out.toolSequence.append(ToolCall(name: part["tool"] as? String ?? "?", input: String(decoding: data, as: UTF8.self)))
            case "text":
                if let t = part["text"] as? String, !t.isEmpty {
                    out.assistantTexts.append(t)
                    textByMessage.append((part["messageID"] as? String ?? "", t))
                }
            case "error":
                let e = obj["error"] as? [String: Any]
                out.error = (e?["message"] as? String) ?? (e?["type"] as? String) ?? "OpenCode reported an error"
            default: break
            }
        }
        out.numTurns = messages.count
        // The answer: the text of the last message that had any.
        if let last = textByMessage.last?.id {
            out.finalOutput = textByMessage.filter { $0.id == last }.map(\.text).joined(separator: "\n")
        }
        return out
    }
}
