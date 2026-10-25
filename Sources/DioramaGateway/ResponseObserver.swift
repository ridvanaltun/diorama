import DioramaCore
import DioramaJSON
import Foundation

/// Watches a relayed response (SSE or JSON) to extract what the timeline needs. It never
/// blocks or alters delivery; capture beyond `captureLimit` bytes is dropped.
struct ResponseObserver {
    let isEventStream: Bool
    let captureLimit: Int
    private(set) var captured: [UInt8] = []
    private(set) var captureTruncated = false
    private var lineBuffer: [UInt8] = []
    private var currentEvent: String?
    private var dataLines: [String] = []

    private(set) var usage: TokenUsage?
    private(set) var stopReason: String?
    private(set) var model: String?
    private(set) var errorMessage: String?
    private var text = ""
    private var toolUses: [Int: (id: String, name: String, json: String)] = [:]
    private var blockTypes: [Int: String] = [:]

    init(contentType: String?, captureLimit: Int = 16 * 1024 * 1024) {
        isEventStream = contentType?.lowercased().contains("text/event-stream") ?? false
        self.captureLimit = captureLimit
    }

    mutating func feed(_ chunk: Data) {
        if captured.count + chunk.count <= captureLimit {
            captured.append(contentsOf: chunk)
        } else {
            captureTruncated = true
        }
        guard isEventStream else { return }
        for b in chunk {
            if b == 0x0A {
                handleLine(lineBuffer)
                lineBuffer.removeAll(keepingCapacity: true)
            } else if lineBuffer.count < 4 * 1024 * 1024 {
                lineBuffer.append(b)
            }
        }
    }

    mutating func finish() {
        if isEventStream {
            if !lineBuffer.isEmpty { handleLine(lineBuffer) }
            dispatch()
        } else if !captureTruncated, let v = try? JSONValue.parse(captured) {
            handleMessageObject(v)
        }
    }

    private mutating func handleLine(_ raw: [UInt8]) {
        var line = raw
        if line.last == 0x0D { line.removeLast() }
        if line.isEmpty {
            dispatch()
            return
        }
        let s = String(decoding: line, as: UTF8.self)
        if s.hasPrefix(":") { return }
        if s.hasPrefix("event:") {
            currentEvent = s.dropFirst(6).trimmingCharacters(in: .whitespaces)
        } else if s.hasPrefix("data:") {
            var d = String(s.dropFirst(5))
            if d.hasPrefix(" ") { d.removeFirst() }
            dataLines.append(d)
        }
    }

    private mutating func dispatch() {
        defer {
            currentEvent = nil
            dataLines.removeAll()
        }
        guard !dataLines.isEmpty, let v = try? JSONValue.parse(dataLines.joined(separator: "\n")) else { return }
        let type = v["type"]?.stringValue ?? currentEvent
        switch type {
        case "message_start":
            if let m = v["message"] {
                model = m["model"]?.stringValue ?? model
                if let u = m["usage"] { usage = Self.usage(u) }
            }
        case "content_block_start":
            let idx = Self.int(v["index"])
            if let block = v["content_block"] {
                let bt = block["type"]?.stringValue ?? ""
                blockTypes[idx] = bt
                if bt == "tool_use" || bt == "server_tool_use" {
                    toolUses[idx] = (block["id"]?.stringValue ?? "", block["name"]?.stringValue ?? "", "")
                } else if bt == "text" {
                    text += block["text"]?.stringValue ?? ""
                }
            }
        case "content_block_delta":
            let idx = Self.int(v["index"])
            if let d = v["delta"] {
                switch d["type"]?.stringValue {
                case "text_delta": if blockTypes[idx] == "text" { text += d["text"]?.stringValue ?? "" }
                case "input_json_delta": toolUses[idx]?.json += d["partial_json"]?.stringValue ?? ""
                default: break
                }
            }
        case "message_delta":
            if let sr = v["delta"]?["stop_reason"]?.stringValue { stopReason = sr }
            if let u = v["usage"] {
                var merged = usage ?? TokenUsage()
                let n = Self.usage(u)
                merged.outputTokens = n.outputTokens
                if n.inputTokens > 0 { merged.inputTokens = n.inputTokens }
                if n.cacheReadTokens > 0 { merged.cacheReadTokens = n.cacheReadTokens }
                if n.cacheWriteTokens > 0 { merged.cacheWriteTokens = n.cacheWriteTokens }
                usage = merged
            }
        case "error":
            errorMessage = v["error"]?["message"]?.stringValue ?? "stream error"
        default:
            break
        }
    }

    private mutating func handleMessageObject(_ v: JSONValue) {
        if v["type"]?.stringValue == "error" {
            errorMessage = v["error"]?["message"]?.stringValue
            return
        }
        model = v["model"]?.stringValue
        stopReason = v["stop_reason"]?.stringValue
        if let u = v["usage"] { usage = Self.usage(u) } else if let n = v["input_tokens"] {
            usage = TokenUsage(inputTokens: Self.int(n))
        }
        if case .array(let blocks)? = v["content"] {
            for (i, b) in blocks.enumerated() {
                switch b["type"]?.stringValue {
                case "text": text += b["text"]?.stringValue ?? ""
                case "tool_use", "server_tool_use":
                    toolUses[i] = (b["id"]?.stringValue ?? "", b["name"]?.stringValue ?? "", b["input"]?.canonicalString ?? "{}")
                default: break
                }
            }
        }
    }

    var assistant: AssistantSummary? {
        if text.isEmpty, toolUses.isEmpty, stopReason == nil { return nil }
        let uses = toolUses.keys.sorted().compactMap { k -> ToolUseSummary? in
            guard let t = toolUses[k] else { return nil }
            let input = t.json.isEmpty ? "{}" : t.json
            return ToolUseSummary(id: t.id, name: t.name, input: String(input.prefix(2000)))
        }
        return AssistantSummary(text: String(text.prefix(20_000)), toolUses: uses, stopReason: stopReason)
    }

    static func int(_ v: JSONValue?) -> Int {
        if case .number(let s)? = v { return Int(s) ?? 0 }
        return 0
    }

    static func usage(_ u: JSONValue) -> TokenUsage {
        TokenUsage(
            inputTokens: int(u["input_tokens"]), outputTokens: int(u["output_tokens"]),
            cacheReadTokens: int(u["cache_read_input_tokens"]), cacheWriteTokens: int(u["cache_creation_input_tokens"]))
    }
}
