import DioramaCore
import DioramaJSON
import DioramaStore
import Foundation

/// Where the text Claude reads lives in a tool's `tool_response`, as Claude Code hands it to a
/// `PostToolUse` hook. Hook mode rewrites only these strings and leaves every other field, so
/// the `updatedToolOutput` it returns keeps the tool's output shape (Claude Code ignores a
/// mismatched shape for built-in tools).
public enum HookOutputMapping {
    public enum Step: Hashable, Sendable {
        case key(String)
        case index(Int)
    }

    public typealias Path = [Step]

    /// Paths to the readable text, in order. Empty when Diorama doesn't know the shape.
    public static func textPaths(toolName: String, response: JSONValue) -> [Path] {
        if case .string = response { return [[]] }
        if case .array(let items) = response { return blockPaths(items, prefix: []) }
        guard case .object(let o) = response else { return [] }
        switch toolName {
        case "Read":
            // Text files only; images, PDFs and notebooks are left alone.
            guard o["type"]?.stringValue == "text" else { return [] }
            return strings(response, [[.key("file"), .key("content")]])
        case "WebFetch":
            return strings(response, [[.key("result")]])
        case "Bash":
            return strings(response, [[.key("stdout")], [.key("stderr")]])
        case "Grep":
            return strings(response, [[.key("content")]])
        case "WebSearch":
            // Best effort: the commentary strings between search result groups.
            guard case .array(let results)? = o["results"] else { return [] }
            return results.indices.compactMap { i in results[i].stringValue.map { _ in [.key("results"), .index(i)] } }
        default:
            // MCP tools and others: content blocks, or one of the usual text fields.
            if case .array(let items)? = o["content"] {
                let paths = blockPaths(items, prefix: [.key("content")])
                if !paths.isEmpty { return paths }
            }
            return strings(response, ["result", "output", "text", "content", "stdout"].map { [.key($0)] }).prefix(1).map { $0 }
        }
    }

    /// `[{type: "text", text: …}, …]` blocks.
    static func blockPaths(_ items: [JSONValue], prefix: Path) -> [Path] {
        items.indices.compactMap { i in
            guard case .object(let b) = items[i], b["type"]?.stringValue == "text", b["text"]?.stringValue != nil else { return nil }
            return prefix + [.index(i), .key("text")]
        }
    }

    /// The candidate paths that hold a non-empty string.
    static func strings(_ value: JSONValue, _ candidates: [Path]) -> [Path] {
        candidates.filter { !(get(value, $0)?.stringValue ?? "").isEmpty }
    }

    public static func get(_ value: JSONValue, _ path: Path) -> JSONValue? {
        var current = value
        for step in path {
            switch (step, current) {
            case (.key(let k), .object(let o)):
                guard let next = o[k] else { return nil }
                current = next
            case (.index(let i), .array(let a)):
                guard a.indices.contains(i) else { return nil }
                current = a[i]
            default: return nil
            }
        }
        return current
    }

    public static func set(_ value: JSONValue, _ path: Path, _ newValue: JSONValue) -> JSONValue {
        guard let step = path.first else { return newValue }
        let rest = Array(path.dropFirst())
        switch (step, value) {
        case (.key(let k), .object(var o)):
            guard let child = o[k] else { return value }
            o[k] = set(child, rest, newValue)
            return .object(o)
        case (.index(let i), .array(var a)):
            guard a.indices.contains(i) else { return value }
            a[i] = set(a[i], rest, newValue)
            return .array(a)
        default:
            return value
        }
    }
}

extension DecisionEngine {
    /// Decides one tool result reported by a `PostToolUse` hook (hook mode). Uses the same rules,
    /// rewrite agent and audit records as the gateway; the decision is keyed by `tool_use_id`, so
    /// a repeated hook call for the same result gets the same bytes back.
    /// Returns the decision and, when rewritten, the JSON to hand back as `updatedToolOutput`.
    public func decideHook(
        session: SessionRecord, toolUseId: String, toolName: String, toolInputJSON: String?, responseJSON: String, taskText: String?
    ) async -> (DecisionRecord?, [UInt8]?) {
        if let existing = try? store.decision(toolUseId: toolUseId) {
            return (existing, replacement(existing))
        }
        guard let response = try? JSONValue.parse(responseJSON) else {
            store.addEvent(sessionId: session.id, kind: .anomaly, message: "Could not parse the \(toolName) result from the hook; left unchanged", refId: toolUseId)
            return (nil, nil)
        }
        // Stored in the same canonical form as the rewrite, so the audit diff shows only real changes.
        let original = response.canonicalBytes
        let input = toolInputJSON.flatMap { try? JSONValue.parse($0) } ?? .object([:])
        let paths = HookOutputMapping.textPaths(toolName: toolName, response: response)
        let segments = paths.compactMap { HookOutputMapping.get(response, $0)?.stringValue }
        let target = DecisionTarget(
            decisionId: toolUseId, toolName: toolName, toolInputJSON: toolInputJSON, matchInput: input, treatmentInput: input,
            isError: false, stage: .result, original: original, hash: Hashing.sha256Hex(original), segments: segments, taskText: taskText,
            missingReason: paths.isEmpty ? "hook mode can't read this \(toolName) output shape" : nil,
            buildReplacement: { newTexts in
                var out = response
                for (path, text) in zip(paths, newTexts) { out = HookOutputMapping.set(out, path, .string(text)) }
                return out.canonicalBytes
            })
        let d = await inflight.decision(for: toolUseId) {
            await self.decide(target, session: session, exchangeId: 0, requestClass: "main")
        }
        return (d, replacement(d))
    }

    func replacement(_ d: DecisionRecord) -> [UInt8]? {
        guard d.outcome == .rewritten, let blob = d.replacementBlob else { return nil }
        return try? store.blobs.get(blob)
    }
}
