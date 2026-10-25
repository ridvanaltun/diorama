import DioramaCore
import DioramaJSON
import DioramaStore
import Foundation

/// WebFetch's summarizing request, as sent by Claude Code: one user message whose text is
/// `\nWeb page content:\n---\n<page>\n---\n\n<prompt>\n\nProvide a concise response…`.
public struct ExtractionRequest: Sendable {
    /// The JSON string node holding the whole message text.
    public var textNode: JSONNode
    public var text: String
    public var page: String
    /// Text before and after the page, kept verbatim when splicing a rewritten page back in.
    public var prefix: String
    public var suffix: String
    public var prompt: String?

    static let pageMarker = "Web page content:\n---\n"
    static let endMarker = "\n---\n\n"
    static let instructionMarker = "\n\nProvide a concise response"

    /// Returns nil unless `body` is a WebFetch extraction request (no tools, one user message
    /// starting with the page marker).
    public static func detect(_ body: [UInt8]) -> ExtractionRequest? {
        guard let root = try? JSONIndex.parse(body), root.kind == .object else { return nil }
        if let tools = root["tools"], !(tools.kind == .array && tools.elements.isEmpty) { return nil }
        guard let messages = root["messages"], messages.kind == .array, messages.elements.count == 1,
              let msg = messages.elements.first, msg.kind == .object,
              let role = msg["role"], (try? JSONIndex.decodeString(body, role)) == "user",
              let content = msg["content"]
        else { return nil }
        var node: JSONNode?
        switch content.kind {
        case .string: node = content
        case .array:
            let texts = content.elements.filter { el in
                el.kind == .object && el["type"].flatMap { try? JSONIndex.decodeString(body, $0) } == "text" && el["text"]?.kind == .string
            }
            node = texts.first?["text"]
        default: return nil
        }
        guard let textNode = node, let text = try? JSONIndex.decodeString(body, textNode) else { return nil }
        let head = text.prefix(64)
        guard let markerRange = text.range(of: pageMarker), head.contains("Web page content:") else { return nil }
        // The page may contain "---" lines (Markdown rules), so the end marker is the *last*
        // "\n---\n\n" before the instructions.
        let searchEnd = text.range(of: instructionMarker, options: .backwards)?.lowerBound ?? text.endIndex
        guard searchEnd > markerRange.upperBound,
              let endRange = text.range(of: endMarker, options: .backwards, range: markerRange.upperBound..<searchEnd)
        else { return nil }
        let page = String(text[markerRange.upperBound..<endRange.lowerBound])
        let afterEnd = text[endRange.upperBound...]
        let promptEnd = afterEnd.range(of: instructionMarker)?.lowerBound ?? afterEnd.endIndex
        let prompt = String(afterEnd[..<promptEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        return ExtractionRequest(
            textNode: textNode, text: text, page: page, prefix: String(text[..<markerRange.upperBound]),
            suffix: String(text[endRange.lowerBound...]), prompt: prompt.isEmpty ? nil : prompt)
    }
}

/// WebFetch calls seen in recent responses, so an extraction request can be tied back to its
/// tool_use id and URL (the extraction request itself contains neither).
actor PendingFetches {
    struct Fetch: Sendable {
        var toolUseId: String
        var url: String?
        var prompt: String?
        var used = false
    }

    private var bySession: [String: [Fetch]] = [:]

    func note(sessionId: String, toolUses: [ToolUseSummary]) {
        var list = bySession[sessionId] ?? []
        for u in toolUses where u.name == "WebFetch" && !list.contains(where: { $0.toolUseId == u.id }) {
            let input = try? JSONValue.parse(u.input)
            list.append(Fetch(toolUseId: u.id, url: input?["url"]?.stringValue, prompt: input?["prompt"]?.stringValue))
        }
        bySession[sessionId] = Array(list.suffix(64))
    }

    /// Picks the unused fetch whose prompt matches; falls back to the only unused one.
    func take(sessionId: String, prompt: String?) -> Fetch? {
        guard var list = bySession[sessionId] else { return nil }
        let unused = list.indices.filter { !list[$0].used }
        var pick: Int?
        if let prompt {
            pick = unused.last { i in
                guard let p = list[i].prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty else { return false }
                return p == prompt || prompt.hasPrefix(p) || p.hasPrefix(prompt)
            }
        }
        if pick == nil, unused.count == 1 { pick = unused.first }
        // A retried extraction request (same prompt) maps to the fetch it matched before, so it
        // resolves to the same decision and is replayed instead of re-decided.
        if pick == nil, let prompt {
            pick = list.indices.last { list[$0].used && list[$0].prompt?.trimmingCharacters(in: .whitespacesAndNewlines) == prompt }
        }
        guard let i = pick else { return nil }
        list[i].used = true
        bySession[sessionId] = list
        return list[i]
    }
}

extension DecisionEngine {
    /// Records WebFetch calls from a response so a following extraction request can be matched.
    public func noteToolUses(sessionId: String, toolUses: [ToolUseSummary]) async {
        guard toolUses.contains(where: { $0.name == "WebFetch" }) else { return }
        await pendingFetches.note(sessionId: sessionId, toolUses: toolUses)
    }

    static func hasPageRules(_ session: SessionRecord) -> Bool {
        (session.profileVersion?.profile.rules.contains { $0.enabled && $0.match.stage == .page } ?? false)
            || session.prompt?.stage == .page
    }

    /// Pre-extraction mode: rewrites the raw page inside WebFetch's summarizing request. Returns
    /// nil when the request isn't an extraction request or the session has no page-stage rules.
    func processExtraction(body: [UInt8], session: SessionRecord, exchangeId: Int64, requestClass: String?) async -> ProcessResult? {
        guard Self.hasPageRules(session), let ex = ExtractionRequest.detect(body) else { return nil }
        let fetch = await pendingFetches.take(sessionId: session.id, prompt: ex.prompt)
        let pageBytes = Array(ex.page.utf8)
        let hash = Hashing.sha256Hex(pageBytes)
        let decisionId = "page:" + (fetch?.toolUseId ?? "sha-" + hash.prefix(24))
        var inputFields: [String: JSONValue] = [:]
        if let url = fetch?.url { inputFields["url"] = .string(url) }
        if let p = fetch?.prompt ?? ex.prompt { inputFields["prompt"] = .string(p) }
        let matchInput = JSONValue.object(inputFields)
        // The prompt is written by Claude and varies between trials; the page is identified by URL.
        let treatmentInput = JSONValue.object(fetch?.url.map { ["url": .string($0)] } ?? [:])

        var decision: DecisionRecord
        var handling: ToolResultHandling
        if let existing = try? store.decision(toolUseId: decisionId), existing.originalHash == hash {
            decision = existing
            handling = existing.outcome == .rewritten ? .replayedRewritten : existing.outcome == .failed ? .replayedFailed : .replayedUnchanged
            store.incrementReplays([decisionId])
        } else {
            let target = DecisionTarget(
                decisionId: decisionId, toolName: "WebFetch", toolInputJSON: matchInput.canonicalString, matchInput: matchInput,
                treatmentInput: treatmentInput, isError: false, stage: .page, original: JSONEncoding.string(ex.page), hash: hash,
                segments: [ex.page], taskText: nil, missingReason: nil,
                buildReplacement: { JSONEncoding.string($0[0]) })
            decision = await inflight.decision(for: decisionId) {
                await self.decide(target, session: session, exchangeId: exchangeId, requestClass: requestClass)
            }
            handling = decision.outcome == .rewritten ? .decidedRewritten : decision.outcome == .failed ? .decidedFailed : .decidedUnchanged
        }
        let entry = ToolResultEntry(toolUseId: decisionId, toolName: "WebFetch (page)", handling: handling)
        guard decision.outcome == .rewritten, let blob = decision.replacementBlob,
              let replacementJSON = try? store.blobs.get(blob),
              let newPage = try? JSONIndex.decodeString(replacementJSON, JSONIndex.parse(replacementJSON))
        else {
            return ProcessResult(forwardedBody: nil, entries: [entry], model: nil)
        }
        let newText = ex.prefix + newPage + ex.suffix
        guard let out = try? JSONSplice.apply(body, [(ex.textNode.range, JSONEncoding.string(newText))]) else {
            return ProcessResult(forwardedBody: nil, entries: [entry], model: nil, scanError: "page splice failed")
        }
        return ProcessResult(forwardedBody: out, entries: [entry], model: nil)
    }
}
