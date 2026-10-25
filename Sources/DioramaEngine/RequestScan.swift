import DioramaJSON
import Foundation

/// One `tool_result` block located in an outgoing Messages request.
public struct ScannedToolResult: Sendable {
    public enum ContentKind: Sendable { case string, blocks, absent, other }

    public var toolUseId: String
    public var messageIndex: Int
    public var blockIndex: Int
    public var isError: Bool
    public var contentKind: ContentKind
    /// The `content` value node (nil when absent).
    public var content: JSONNode?
    /// String nodes holding the text of the result (the string itself, or each text block's `text`).
    public var textSegments: [JSONNode]
}

public struct ScannedToolUse: Sendable {
    public var id: String
    public var name: String
    /// Raw JSON bytes of `input`.
    public var inputJSON: String
}

/// Result of scanning a `/v1/messages` (or `count_tokens`) request body.
public struct ScannedRequest: Sendable {
    public var model: String?
    public var stream: Bool
    public var messageCount: Int
    public var toolUses: [String: ScannedToolUse]
    public var toolResults: [ScannedToolResult]
    /// Text of the first user message, with `<system-reminder>` sections removed.
    public var taskText: String?

    /// Scans `bytes` without modifying them.
    public static func scan(_ bytes: [UInt8]) throws -> ScannedRequest {
        let root = try JSONIndex.parse(bytes)
        guard root.kind == .object else { throw JSONParseError(offset: 0, message: "request body is not an object") }
        var model: String?
        if let m = root["model"], m.kind == .string { model = try JSONIndex.decodeString(bytes, m) }
        let stream = root["stream"].map { $0.kind == .bool && bytes[$0.range.lowerBound] == UInt8(ascii: "t") } ?? false
        var uses: [String: ScannedToolUse] = [:]
        var results: [ScannedToolResult] = []
        var task: String?
        let messages = root["messages"]?.kind == .array ? root["messages"]!.elements : []

        for (mi, msg) in messages.enumerated() {
            guard msg.kind == .object else { continue }
            let role = try msg["role"].flatMap { $0.kind == .string ? try JSONIndex.decodeString(bytes, $0) : nil }
            guard let content = msg["content"] else { continue }

            if role == "user", task == nil {
                task = try Self.text(of: content, bytes)
            }
            guard content.kind == .array else { continue }
            for (bi, block) in content.elements.enumerated() {
                guard block.kind == .object, let typeNode = block["type"], typeNode.kind == .string else { continue }
                let type = try JSONIndex.decodeString(bytes, typeNode)
                if role == "assistant", type == "tool_use" || type == "server_tool_use" {
                    guard let idNode = block["id"], idNode.kind == .string, let nameNode = block["name"], nameNode.kind == .string else { continue }
                    let id = try JSONIndex.decodeString(bytes, idNode)
                    let input = block["input"].map { String(decoding: bytes[$0.range], as: UTF8.self) } ?? "{}"
                    uses[id] = ScannedToolUse(id: id, name: try JSONIndex.decodeString(bytes, nameNode), inputJSON: input)
                } else if role == "user", type == "tool_result" {
                    guard let idNode = block["tool_use_id"], idNode.kind == .string else { continue }
                    let id = try JSONIndex.decodeString(bytes, idNode)
                    let isError = block["is_error"].map { $0.kind == .bool && bytes[$0.range.lowerBound] == UInt8(ascii: "t") } ?? false
                    let c = block["content"]
                    var kind = ScannedToolResult.ContentKind.absent
                    var segments: [JSONNode] = []
                    if let c {
                        switch c.kind {
                        case .string:
                            kind = .string
                            segments = [c]
                        case .array:
                            kind = .blocks
                            for el in c.elements where el.kind == .object {
                                if let t = el["type"], t.kind == .string, try JSONIndex.decodeString(bytes, t) == "text",
                                   let text = el["text"], text.kind == .string {
                                    segments.append(text)
                                }
                            }
                        default:
                            kind = .other
                        }
                    }
                    results.append(ScannedToolResult(
                        toolUseId: id, messageIndex: mi, blockIndex: bi, isError: isError, contentKind: kind, content: c,
                        textSegments: segments))
                }
            }
        }
        return ScannedRequest(
            model: model, stream: stream, messageCount: messages.count, toolUses: uses, toolResults: results,
            taskText: task.map(Self.stripReminders))
    }

    static func text(of content: JSONNode, _ bytes: [UInt8]) throws -> String? {
        switch content.kind {
        case .string: return try JSONIndex.decodeString(bytes, content)
        case .array:
            var parts: [String] = []
            for el in content.elements where el.kind == .object {
                if let t = el["type"], t.kind == .string, try JSONIndex.decodeString(bytes, t) == "text",
                   let text = el["text"], text.kind == .string {
                    parts.append(try JSONIndex.decodeString(bytes, text))
                }
            }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        default: return nil
        }
    }

    static func stripReminders(_ s: String) -> String {
        var out = s
        while let start = out.range(of: "<system-reminder>"),
              let end = out.range(of: "</system-reminder>", range: start.upperBound..<out.endIndex) {
            out.removeSubrange(start.lowerBound..<end.upperBound)
        }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 4000 ? String(trimmed.prefix(4000)) + "…" : trimmed
    }
}
