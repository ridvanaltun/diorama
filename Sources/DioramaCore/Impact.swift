import Foundation

/// Did a rewrite reach Claude's work? A heuristic read of what Claude wrote and did after a
/// rewritten tool result, starting with the response that received it. Interpretations, not
/// facts: every flag lists the evidence that raised it.
public struct DecisionImpact: Codable, Sendable, Hashable, Identifiable {
    public enum Signal: String, Codable, Sendable, CaseIterable {
        /// Text the rewrite introduced appears in Claude's later replies or tool inputs.
        case used
        /// Claude's later text questions the content ("looks altered", "can't verify", …).
        case questioned
        /// Claude re-fetched the same URL or ran a network command afterwards.
        case checked
        /// Text the rewrite removed appears in Claude's later output anyway.
        case originalSurfaced
    }

    public enum Status: String, Codable, Sendable {
        /// At least one signal.
        case signals
        /// Claude responded afterwards, without any of the signals.
        case noSign
        /// Nothing after this result yet.
        case pending
        /// Hook mode: Claude's replies aren't visible, and later tool calls showed nothing.
        case notVisible
    }

    public var toolUseId: String
    public var status: Status
    public var signals: [Signal]
    public var evidence: [String]
    public var id: String { toolUseId }

    public init(toolUseId: String, status: Status, signals: [Signal], evidence: [String]) {
        self.toolUseId = toolUseId
        self.status = status
        self.signals = signals
        self.evidence = evidence
    }

    /// The headline: the strongest signal, or the status.
    public var label: String {
        if signals.contains(.used) { return "used" }
        if signals.contains(.questioned) { return "questioned" }
        if signals.contains(.checked) { return "checked" }
        if signals.contains(.originalSurfaced) { return "original surfaced" }
        switch status {
        case .noSign: return "no sign"
        case .pending: return "pending"
        case .notVisible, .signals: return "not visible"
        }
    }
}

public enum ImpactAnalysis {
    /// One rewritten result: its id, the exchange that carried it, when it was decided, the
    /// readable original and replacement, and the tool input (for re-fetch detection).
    public struct Rewrite: Sendable {
        public var toolUseId: String
        public var exchangeId: Int64
        public var decidedAt: Date
        public var toolName: String?
        public var toolInput: String?
        public var original: String
        public var replacement: String

        public init(toolUseId: String, exchangeId: Int64, decidedAt: Date, toolName: String?, toolInput: String?, original: String, replacement: String) {
            self.toolUseId = toolUseId
            self.exchangeId = exchangeId
            self.decidedAt = decidedAt
            self.toolName = toolName
            self.toolInput = toolInput
            self.original = original
            self.replacement = replacement
        }
    }

    /// Something Claude produced: a reply (gateway) or a later tool call (gateway or hook).
    public struct Output: Sendable {
        public var exchangeId: Int64?
        public var at: Date
        public var text: String
        public var toolCalls: [(name: String, input: String)]

        public init(exchangeId: Int64?, at: Date, text: String, toolCalls: [(name: String, input: String)]) {
            self.exchangeId = exchangeId
            self.at = at
            self.text = text
            self.toolCalls = toolCalls
        }
    }

    public static let suspicionPatterns = [
        "tamper", "altered", "been modified", "was modified", "injected", "manipulat", "doesn't match", "does not match",
        "inconsistent with", "suspicious", "been rewritten", "can't verify", "cannot verify", "couldn't verify",
        "don't trust", "do not trust", "not trustworthy", "seems off", "looks off",
    ]

    /// Gateway sessions: from the timeline's exchanges. `repliesVisible` is false in hook mode.
    public static func outputs(_ t: Timeline) -> [Output] {
        var out = t.exchanges.filter { ["main", "subagent"].contains($0.requestClass ?? "main") }.compactMap { e -> Output? in
            guard let a = e.assistant else { return nil }
            return Output(exchangeId: e.id, at: e.startedAt, text: a.text, toolCalls: a.toolUses.map { ($0.name, $0.input) })
        }
        if t.session.isHook {
            // Hook mode sees tool calls (as later decisions' inputs), not replies.
            out = t.decisions.filter { !$0.toolUseId.hasPrefix("page:") }.map {
                Output(exchangeId: nil, at: $0.createdAt, text: "", toolCalls: [($0.toolName ?? "tool", $0.toolInput ?? "")])
            }
        }
        return out
    }

    public static func analyze(_ r: Rewrite, outputs: [Output], repliesVisible: Bool) -> DecisionImpact {
        // The response to the request that carried the result, and everything after it.
        let later = outputs.filter { o in o.exchangeId.map { $0 >= r.exchangeId } ?? (o.at > r.decidedAt) }
        guard !later.isEmpty else {
            return DecisionImpact(toolUseId: r.toolUseId, status: repliesVisible ? .pending : .notVisible, signals: [], evidence: [])
        }
        let corpus = later.map { o in ([o.text] + o.toolCalls.map(\.input)).joined(separator: "\n") }.joined(separator: "\n").lowercased()
        // What Claude wrote (not tool inputs, where e.g. a URL can contain a removed word).
        let prose = later.map(\.text).joined(separator: "\n").lowercased()
        var signals: [DecisionImpact.Signal] = []
        var evidence: [String] = []

        let (added, removed) = changedText(original: r.original, replacement: r.replacement)
        let usedHits = added.filter { corpus.contains($0.lowercased()) }
        if !usedHits.isEmpty {
            signals.append(.used)
            evidence.append("Claude repeated text the rewrite introduced: " + usedHits.prefix(3).map { "“\($0)”" }.joined(separator: ", "))
        }
        let suspicion = suspicionPatterns.filter { prose.contains($0) }
        if repliesVisible, !suspicion.isEmpty {
            signals.append(.questioned)
            evidence.append("Claude's later text says: " + suspicion.prefix(3).map { "“\($0)”" }.joined(separator: ", "))
        }
        let calls = later.flatMap(\.toolCalls)
        if r.toolName == "WebFetch", let url = jsonString(r.toolInput, "url"),
           calls.contains(where: { $0.name == "WebFetch" && jsonString($0.input, "url") == url }) {
            signals.append(.checked)
            evidence.append("Claude fetched \(url) again")
        } else if let net = calls.first(where: { $0.name == "Bash" && ["curl ", "wget ", "http ", "lynx "].contains(where: $0.input.lowercased().contains) }) {
            signals.append(.checked)
            evidence.append("network command afterwards: " + String(net.input.prefix(100)))
        }
        let surfaced = removed.filter { prose.contains($0.lowercased()) }
        if !surfaced.isEmpty {
            signals.append(.originalSurfaced)
            evidence.append("text the rewrite removed appears later: " + surfaced.prefix(3).map { "“\($0)”" }.joined(separator: ", "))
        }
        let replied = later.contains { !$0.text.isEmpty || !$0.toolCalls.isEmpty }
        let status: DecisionImpact.Status = !signals.isEmpty ? .signals : replied ? (repliesVisible ? .noSign : .notVisible) : .pending
        return DecisionImpact(toolUseId: r.toolUseId, status: status, signals: signals, evidence: evidence)
    }

    /// Phrases the rewrite inserted and removed (word diff), each only when the other side doesn't
    /// also contain it. A change is widened to whole words (the diff can split "2.3" into "2." and
    /// "3"), and a short one also takes a neighboring word on each side ("version 2.4 is"), so it's
    /// specific enough to look for.
    static func changedText(original: String, replacement: String) -> (added: [String], removed: [String]) {
        var added: [String] = [], removed: [String] = []
        let o = original.lowercased(), n = replacement.lowercased()
        let segs = TextDiff.diff(original, replacement)
        /// The nearest unchanged text before (step -1) or after (+1) segment i.
        func equalText(_ i: Int, _ step: Int) -> String {
            var j = i + step
            while segs.indices.contains(j) {
                if segs[j].op == .equal { return segs[j].text }
                j += step
            }
            return ""
        }
        for (i, seg) in segs.enumerated() where seg.op != .equal {
            let left = equalText(i, -1), right = equalText(i, 1)
            // Partial words glued to the change, then whole words around it.
            let leftWords = left.split(omittingEmptySubsequences: false, whereSeparator: \.isWhitespace).map(String.init)
            let rightWords = right.split(omittingEmptySubsequences: false, whereSeparator: \.isWhitespace).map(String.init)
            let gluedLeft = left.last.map { $0.isWhitespace } == false ? (leftWords.last ?? "") : ""
            let gluedRight = right.first.map { $0.isWhitespace } == false ? (rightWords.first ?? "") : ""
            var core = (gluedLeft + seg.text + gluedRight).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !core.isEmpty else { continue }
            if core.filter({ !$0.isWhitespace }).count < 8 {
                let before = leftWords.dropLast(gluedLeft.isEmpty ? 0 : 1).last { !$0.isEmpty } ?? ""
                let after = rightWords.dropFirst(gluedRight.isEmpty ? 0 : 1).first { !$0.isEmpty } ?? ""
                core = [before, core, after].filter { !$0.isEmpty }.joined(separator: " ")
            }
            let phrase = String(core.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).prefix(120))
            guard phrase.filter({ !$0.isWhitespace }).count >= 5 else { continue }
            if seg.op == .insert, !o.contains(phrase.lowercased()), !added.contains(phrase) { added.append(phrase) }
            if seg.op == .delete, !n.contains(phrase.lowercased()), !removed.contains(phrase) { removed.append(phrase) }
        }
        return (added, removed)
    }

    static func jsonString(_ json: String?, _ key: String) -> String? {
        guard let data = json?.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj[key] as? String
    }
}
