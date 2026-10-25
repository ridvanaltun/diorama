import Foundation

/// A fake Claude model for driving the real Claude Code CLI deterministically: it calls the
/// scripted tools in order, then answers with every tool result it received ("MODEL SAW: …"),
/// which lets tests observe exactly what the model was given.
public final class ScriptedModel: @unchecked Sendable {
    public struct Step: Sendable {
        public var tool: String
        public var input: [String: String]
        public init(_ tool: String, _ input: [String: String]) {
            self.tool = tool
            self.input = input
        }
    }

    public let steps: [Step]
    private let lock = NSLock()
    private var _mainRequests: [[String: Any]] = []

    public init(steps: [Step]) { self.steps = steps }

    /// Main-conversation request bodies (decoded) in arrival order.
    public var mainRequests: [[String: Any]] { lock.withLock { _mainRequests } }

    public func respond(_ req: MockUpstream.Request) -> MockUpstream.Response {
        if req.uri.hasPrefix("/v1/messages/count_tokens") { return .json(#"{"input_tokens":100}"#) }
        guard req.uri.hasPrefix("/v1/messages"),
              let body = try? JSONSerialization.jsonObject(with: Data(req.body)) as? [String: Any]
        else { return .json("{}") }
        let tools = (body["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        let stream = body["stream"] as? Bool ?? false
        let messages = body["messages"] as? [[String: Any]] ?? []
        let isMain = tools.contains("Read") || tools.contains("Bash")
        guard isMain else {
            // WebFetch's summarizing request: answer with the page we were given, so tests can
            // see exactly what the extraction model received.
            if let first = messages.first, let text = Self.firstText(first["content"]), text.contains("Web page content:\n---\n"),
               let start = text.range(of: "Web page content:\n---\n"),
               let end = text.range(of: "\n---\n\n", options: .backwards) {
                return reply(text: "PAGE SAW: " + String(text[start.upperBound..<end.lowerBound]), stream: stream)
            }
            let wantsJSON = (body["output_config"] as? [String: Any])?["format"] != nil
            return reply(text: wantsJSON ? #"{"title":"test"}"# : "ok", stream: stream)
        }
        lock.withLock { _mainRequests.append(body) }
        var results: [String] = []
        for m in messages where m["role"] as? String == "user" {
            for b in m["content"] as? [[String: Any]] ?? [] where b["type"] as? String == "tool_result" {
                results.append(Self.text(of: b["content"]) + ((b["is_error"] as? Bool ?? false) ? " [is_error]" : ""))
            }
        }
        if results.count < steps.count {
            let s = steps[results.count]
            let id = "toolu_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24).lowercased()
            return replyTool(id: id, name: s.tool, input: s.input, stream: stream)
        }
        let saw = results.enumerated().map { "#\($0.offset + 1) \($0.element)" }.joined(separator: "\n")
        return reply(text: "MODEL SAW:\n" + saw, stream: stream)
    }

    static func firstText(_ content: Any?) -> String? {
        if let s = content as? String { return s }
        return (content as? [[String: Any]])?.first { $0["type"] as? String == "text" }?["text"] as? String
    }

    static func text(of content: Any?) -> String {
        if let s = content as? String { return s }
        if let blocks = content as? [[String: Any]] {
            return blocks.map { b in (b["type"] as? String) == "text" ? (b["text"] as? String ?? "") : "[\(b["type"] as? String ?? "?")]" }.joined(separator: " ")
        }
        return ""
    }

    func reply(text: String, stream: Bool) -> MockUpstream.Response {
        if stream { return .sse(MockUpstream.sseEvents(text: text)) }
        let t = String(decoding: JSONEncodingHelper.string(text), as: UTF8.self)
        return .json(#"{"id":"msg_s","type":"message","role":"assistant","model":"claude-opus-5-5","content":[{"type":"text","text":\#(t)}],"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":10,"output_tokens":5}}"#)
    }

    func replyTool(id: String, name: String, input: [String: String], stream: Bool) -> MockUpstream.Response {
        let inputJSON = String(decoding: try! JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        if stream { return .sse(MockUpstream.sseEvents(toolUse: (id, name, inputJSON))) }
        return .json(#"{"id":"msg_t","type":"message","role":"assistant","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":\#(inputJSON)}],"stop_reason":"tool_use","stop_sequence":null,"usage":{"input_tokens":10,"output_tokens":5}}"#)
    }
}
