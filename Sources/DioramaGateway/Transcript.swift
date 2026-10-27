import DioramaCore
import DioramaEngine
import Foundation

/// Claude's replies, read from a Claude Code session transcript (JSONL). Hook mode can't see model
/// traffic, so this is how it learns what Claude said and did after a tool result. The format is
/// Claude Code's own and undocumented: only `assistant` lines with a timestamp and `text` or
/// `tool_use` blocks are read (never thinking), and anything unexpected is skipped.
enum Transcript {
    struct Reply: Sendable {
        var at: Date
        var text: String
        var toolUses: [ToolUseSummary]
    }

    static let maxBytes = 64_000_000

    static func replies(path: String) -> [Reply]? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxBytes)) ?? Data()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        var out: [Reply] = []
        // Consecutive assistant lines are one response (Claude Code writes a block per line); a user
        // line (the next prompt or a tool result) starts a new one.
        var continuing = false
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard line.count < 4_000_000, let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if obj["type"] as? String == "user" { continuing = false }
            guard obj["type"] as? String == "assistant", let message = obj["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]],
                  let stamp = obj["timestamp"] as? String, let at = iso.date(from: stamp) ?? isoPlain.date(from: stamp)
            else { continue }
            var text: [String] = []
            var uses: [ToolUseSummary] = []
            for b in blocks {
                switch b["type"] as? String {
                case "text": if let t = b["text"] as? String, !t.isEmpty { text.append(t) }
                case "tool_use":
                    let input = (b["input"]).flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.withoutEscapingSlashes]) }
                        .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                    uses.append(ToolUseSummary(id: b["id"] as? String ?? "", name: b["name"] as? String ?? "tool", input: input))
                default: break
                }
            }
            guard !text.isEmpty || !uses.isEmpty else { continue }
            if continuing, let last = out.last {
                out[out.count - 1] = Reply(at: last.at, text: ([last.text] + text).filter { !$0.isEmpty }.joined(separator: "\n"), toolUses: last.toolUses + uses)
            } else {
                out.append(Reply(at: at, text: text.joined(separator: "\n"), toolUses: uses))
            }
            continuing = true
        }
        return out
    }

    /// Claude's first reply after `date` (what it did next), if the transcript shows one.
    static func firstReply(path: String, after date: Date) -> AssistantSummary? {
        guard let r = replies(path: path)?.first(where: { $0.at > date }) else { return nil }
        return AssistantSummary(text: r.text, toolUses: r.toolUses)
    }
}
