import DioramaCore
import Foundation

/// A frozen decision for one `tool_use_id` (decision D9).
public struct DecisionRecord: Sendable, Hashable {
    public var toolUseId: String
    public var sessionId: String
    public var exchangeId: Int64
    public var toolName: String?
    public var toolInput: String?
    public var isError: Bool
    public var originalHash: String
    /// Blob key of the original content JSON bytes.
    public var originalBlob: String
    public var outcome: DecisionOutcome
    public var reason: String
    /// Blob key of the exact replacement content JSON bytes (rewritten only).
    public var replacementBlob: String?
    public var rules: [RuleRef]
    public var instructions: [String]
    public var createdAt: Date
    public var replayCount: Int
    public var treatmentKey: String?

    public init(
        toolUseId: String, sessionId: String, exchangeId: Int64, toolName: String?, toolInput: String?, isError: Bool,
        originalHash: String, originalBlob: String, outcome: DecisionOutcome, reason: String, replacementBlob: String?,
        rules: [RuleRef], instructions: [String], createdAt: Date = Date(), replayCount: Int = 0, treatmentKey: String? = nil
    ) {
        self.toolUseId = toolUseId
        self.sessionId = sessionId
        self.exchangeId = exchangeId
        self.toolName = toolName
        self.toolInput = toolInput
        self.isError = isError
        self.originalHash = originalHash
        self.originalBlob = originalBlob
        self.outcome = outcome
        self.reason = reason
        self.replacementBlob = replacementBlob
        self.rules = rules
        self.instructions = instructions
        self.createdAt = createdAt
        self.replayCount = replayCount
        self.treatmentKey = treatmentKey
    }

    public var summary: DecisionSummary {
        DecisionSummary(
            toolUseId: toolUseId, sessionId: sessionId, exchangeId: exchangeId, toolName: toolName, outcome: outcome,
            reason: reason, createdAt: createdAt, rules: rules, replayCount: replayCount, toolInput: toolInput)
    }
}

public struct AttemptRecord: Sendable {
    public var info: RewriteAttemptInfo
    public var toolUseId: String
    public var sessionId: String?
    public var requestBlob: String?
    public var responseBlob: String?

    public init(info: RewriteAttemptInfo, toolUseId: String, sessionId: String?, requestBlob: String?, responseBlob: String?) {
        self.info = info
        self.toolUseId = toolUseId
        self.sessionId = sessionId
        self.requestBlob = requestBlob
        self.responseBlob = responseBlob
    }
}

extension Store {
    func decisionRecord(_ r: Row) -> DecisionRecord {
        DecisionRecord(
            toolUseId: r.string("tool_use_id") ?? "", sessionId: r.string("session_id") ?? "", exchangeId: r.int("exchange_id") ?? 0,
            toolName: r.string("tool_name"), toolInput: r.string("tool_input"), isError: r.bool("is_error"),
            originalHash: r.string("original_hash") ?? "", originalBlob: r.string("original_blob") ?? "",
            outcome: DecisionOutcome(rawValue: r.string("outcome") ?? "") ?? .unchanged, reason: r.string("reason") ?? "",
            replacementBlob: r.string("replacement_blob"), rules: decode([RuleRef].self, r.string("rules")) ?? [],
            instructions: decode([String].self, r.string("instructions")) ?? [], createdAt: r.date("created_at") ?? Date(),
            replayCount: Int(r.int("replay_count") ?? 0), treatmentKey: r.string("treatment_key"))
    }

    public func decision(toolUseId: String) throws -> DecisionRecord? {
        try db.query("SELECT * FROM decisions WHERE tool_use_id = ?", [.text(toolUseId)]).first.map(decisionRecord)
    }

    public func decisions(toolUseIds: [String]) throws -> [String: DecisionRecord] {
        guard !toolUseIds.isEmpty else { return [:] }
        var out: [String: DecisionRecord] = [:]
        // Chunk to stay under SQLite's parameter limit.
        for chunk in stride(from: 0, to: toolUseIds.count, by: 500).map({ Array(toolUseIds[$0..<min($0 + 500, toolUseIds.count)]) }) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            for r in try db.query("SELECT * FROM decisions WHERE tool_use_id IN (\(marks))", chunk.map { .text($0) }) {
                let d = decisionRecord(r)
                out[d.toolUseId] = d
            }
        }
        return out
    }

    public func decisions(sessionId: String) throws -> [DecisionRecord] {
        try db.query("SELECT * FROM decisions WHERE session_id = ? ORDER BY created_at, rowid", [.text(sessionId)]).map(decisionRecord)
    }

    /// Inserts a decision. If one already exists for the id (a concurrent writer won), the
    /// existing record is returned instead — the first decision is authoritative.
    public func insertDecision(_ d: DecisionRecord) throws -> DecisionRecord {
        try db.transaction {
            if let existing = try decision(toolUseId: d.toolUseId) { return existing }
            try db.run(
                """
                INSERT INTO decisions(tool_use_id, session_id, exchange_id, tool_name, tool_input, is_error, original_hash,
                  original_blob, outcome, reason, replacement_blob, rules, instructions, created_at, replay_count, treatment_key)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)
                """,
                [
                    .text(d.toolUseId), .text(d.sessionId), .int(d.exchangeId), .optional(d.toolName), .optional(d.toolInput),
                    .int(d.isError ? 1 : 0), .text(d.originalHash), .text(d.originalBlob), .text(d.outcome.rawValue), .text(d.reason),
                    .optional(d.replacementBlob), .text(json(d.rules)), .text(json(d.instructions)), .date(d.createdAt),
                    .optional(d.treatmentKey),
                ])
            return d
        }
    }

    public func incrementReplays(_ toolUseIds: [String]) {
        guard !toolUseIds.isEmpty else { return }
        let marks = Array(repeating: "?", count: toolUseIds.count).joined(separator: ",")
        _ = try? db.run("UPDATE decisions SET replay_count = replay_count + 1 WHERE tool_use_id IN (\(marks))", toolUseIds.map { .text($0) })
    }

    // MARK: Rewrite attempts

    public func insertAttempt(_ a: AttemptRecord) throws {
        let i = a.info
        try db.run(
            """
            INSERT INTO rewrite_attempts(id, tool_use_id, session_id, provider, model_requested, model_served, prompt_version,
              status, error, usage, cost_usd, latency_ms, explanation, mode, edits, request_blob, response_blob, created_at)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(i.id), .text(a.toolUseId), .optional(a.sessionId), .text(i.provider), .text(i.modelRequested),
                .optional(i.modelServed), .text(i.promptVersion), .text(i.status.rawValue), .optional(i.error),
                i.usage.map { .text(json($0)) } ?? .null, .optional(i.costUSD), .double(i.latencyMs), .optional(i.explanation),
                .optional(i.mode), .text(json(i.edits)), .optional(a.requestBlob), .optional(a.responseBlob), .date(i.createdAt),
            ])
    }

    public func attempts(toolUseId: String) throws -> [RewriteAttemptInfo] {
        try db.query("SELECT * FROM rewrite_attempts WHERE tool_use_id = ? ORDER BY created_at", [.text(toolUseId)]).map { r in
            RewriteAttemptInfo(
                id: r.string("id") ?? "", provider: r.string("provider") ?? "", modelRequested: r.string("model_requested") ?? "",
                modelServed: r.string("model_served"), promptVersion: r.string("prompt_version") ?? "",
                status: RewriteAttemptStatus(rawValue: r.string("status") ?? "") ?? .failed, error: r.string("error"),
                usage: decode(TokenUsage.self, r.string("usage")), costUSD: r.double("cost_usd"), latencyMs: r.double("latency_ms") ?? 0,
                explanation: r.string("explanation"), mode: r.string("mode"), edits: decode([ContentEdit].self, r.string("edits")) ?? [],
                createdAt: r.date("created_at") ?? Date())
        }
    }

    // MARK: Treatment cache (experiments, decision D11)

    public func treatment(key: String) throws -> (replacementBlob: String, attemptId: String?)? {
        guard let r = try db.query("SELECT * FROM treatment_cache WHERE key = ?", [.text(key)]).first,
              let blob = r.string("replacement_blob")
        else { return nil }
        return (blob, r.string("attempt_id"))
    }

    public func storeTreatment(key: String, replacementBlob: String, attemptId: String?) throws {
        try db.run(
            "INSERT OR IGNORE INTO treatment_cache(key, replacement_blob, attempt_id, created_at) VALUES(?, ?, ?, ?)",
            [.text(key), .text(replacementBlob), .optional(attemptId), .date(Date())])
    }

    // MARK: Detail

    /// The latest decisions across sessions, newest first, with their session's name.
    public func recentDecisions(limit: Int = 50) throws -> [(DecisionRecord, String)] {
        try db.query(
            "SELECT d.*, s.name AS session_name FROM decisions d JOIN sessions s ON s.id = d.session_id ORDER BY d.created_at DESC LIMIT ?",
            [.int(Int64(limit))]
        ).map { (try decisionRecord($0), $0.string("session_name") ?? "") }
    }

    public func decisionDetail(toolUseId: String) throws -> DecisionDetail? {
        guard let d = try decision(toolUseId: toolUseId) else { return nil }
        let original = (try? blobs.getString(d.originalBlob)) ?? ""
        let replacement = d.replacementBlob.flatMap { try? blobs.getString($0) }
        let followUp = try exchange(id: d.exchangeId)
        return DecisionDetail(
            summary: d.summary, toolInput: d.toolInput, isError: d.isError,
            originalText: ContentText.displayText(fromContentJSON: original),
            replacementText: replacement.map { ContentText.displayText(fromContentJSON: $0) }, instructions: d.instructions,
            attempts: try attempts(toolUseId: toolUseId), followUp: followUp?.assistant, followUpExchangeId: followUp?.id)
    }
}

/// Turns stored tool_result content JSON (string or block array) into readable text.
public enum ContentText {
    public static func displayText(fromContentJSON json: String) -> String {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return json }
        if let s = obj as? String { return s }
        if let blocks = obj as? [[String: Any]] {
            return blocks.map { b -> String in
                if (b["type"] as? String) == "text", let t = b["text"] as? String { return t }
                return "[\(b["type"] as? String ?? "block")]"
            }.joined(separator: "\n\n")
        }
        return json
    }
}
