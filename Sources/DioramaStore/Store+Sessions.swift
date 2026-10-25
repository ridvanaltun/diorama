import DioramaCore
import Foundation

/// Full session state as the engine needs it (frozen configuration resolved).
public struct SessionRecord: Sendable, Hashable {
    public var id: String
    public var name: String
    public var cwd: String
    public var kind: SessionKind
    public var status: SessionStatus
    public var createdAt: Date
    public var endedAt: Date?
    public var profileId: String?
    public var profileVersion: ProfileVersionInfo?
    public var prompt: SessionPrompt?
    public var lockdown: LockdownPreset
    public var trialId: String?
    public var onFailure: FailurePolicy?
    /// Scope for frozen experiment treatments (nil = no cross-session reuse).
    public var treatmentScope: String?
    public var claudeSessionIds: [String]
    public var flags: [String]
    public var via: SessionVia = .gateway
    /// Claude Code's transcript (hook mode only).
    public var transcriptPath: String?
    /// Steering paused for this session: AI rewrites and input rules stop; redaction keeps working.
    public var paused = false
    public var notes = ""
    public var tags: [String] = []
    public var archived = false
    /// Profile rule ids (or "session-prompt") switched off for this session only.
    public var disabledRules: [String] = []
}

extension Store {
    // MARK: Sessions

    public func createSession(_ spec: SessionSpec, tokenHash: String) throws -> SessionRecord {
        var version: ProfileVersionInfo?
        if let p = spec.profile, !p.isEmpty {
            guard let v = try resolveProfile(p) else { throw StoreError("unknown profile '\(p)'") }
            version = v
        }
        if let prompt = spec.prompt, prompt.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw StoreError("session prompt is empty")
        }
        let id = Hashing.newId(prefix: "ses")
        let now = Date()
        try db.run(
            """
            INSERT INTO sessions(id, token_hash, name, cwd, kind, status, created_at, profile_id, profile_version_id,
              prompt, lockdown, trial_id, on_failure, treatment_scope, via)
            VALUES(?, ?, ?, ?, ?, 'active', ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(id), .text(tokenHash), .text(spec.name), .text(spec.cwd), .text(spec.kind.rawValue), .date(now),
                .optional(version?.profileId), .optional(version?.id), spec.prompt.map { .text(json($0)) } ?? .null,
                .text(spec.lockdown.rawValue), .optional(spec.trialId), .optional(spec.onFailure?.rawValue),
                .optional(spec.treatmentScope), .text((spec.via ?? .gateway).rawValue),
            ])
        addEvent(sessionId: id, kind: .sessionCreated, message: "Session '\(spec.name)' created", refId: id)
        return SessionRecord(
            id: id, name: spec.name, cwd: spec.cwd, kind: spec.kind, status: .active, createdAt: now, endedAt: nil,
            profileId: version?.profileId, profileVersion: version, prompt: spec.prompt, lockdown: spec.lockdown,
            trialId: spec.trialId, onFailure: spec.onFailure, treatmentScope: spec.treatmentScope, claudeSessionIds: [], flags: [],
            via: spec.via ?? .gateway)
    }

    func sessionRecord(_ r: Row) throws -> SessionRecord {
        let version = try r.string("profile_version_id").flatMap { try profileVersion(id: $0) }
        return SessionRecord(
            id: r.string("id") ?? "", name: r.string("name") ?? "", cwd: r.string("cwd") ?? "",
            kind: SessionKind(rawValue: r.string("kind") ?? "") ?? .interactive,
            status: SessionStatus(rawValue: r.string("status") ?? "") ?? .ended, createdAt: r.date("created_at") ?? Date(),
            endedAt: r.date("ended_at"), profileId: r.string("profile_id"), profileVersion: version,
            prompt: decode(SessionPrompt.self, r.string("prompt")),
            lockdown: LockdownPreset(rawValue: r.string("lockdown") ?? "") ?? .none, trialId: r.string("trial_id"),
            onFailure: r.string("on_failure").flatMap(FailurePolicy.init(rawValue:)),
            treatmentScope: r.string("treatment_scope"),
            claudeSessionIds: decode([String].self, r.string("claude_session_ids")) ?? [],
            flags: decode([String].self, r.string("flags")) ?? [],
            via: SessionVia(rawValue: r.string("via") ?? "") ?? .gateway, transcriptPath: r.string("transcript_path"),
            paused: (r.int("paused") ?? 0) != 0, notes: r.string("notes") ?? "", tags: decode([String].self, r.string("tags")) ?? [],
            archived: (r.int("archived") ?? 0) != 0, disabledRules: decode([String].self, r.string("disabled_rules")) ?? [])
    }

    public func session(id: String) throws -> SessionRecord? {
        try db.query("SELECT * FROM sessions WHERE id = ?", [.text(id)]).first.map(sessionRecord)
    }

    public func session(tokenHash: String) throws -> SessionRecord? {
        try db.query("SELECT * FROM sessions WHERE token_hash = ?", [.text(tokenHash)]).first.map(sessionRecord)
    }

    public enum ArchiveFilter: String, Sendable { case hide, only, all }

    public func sessions(kind: SessionKind? = nil, tag: String? = nil, archived: ArchiveFilter = .hide, limit: Int = 200) throws -> [SessionRecord] {
        var clauses = ["1 = 1"]
        var params: [SQLValue] = []
        switch archived {
        case .hide: clauses.append("archived = 0")
        case .only: clauses.append("archived = 1")
        case .all: break
        }
        if let kind { clauses.append("kind = ?"); params.append(.text(kind.rawValue)) }
        if let tag { clauses.append("EXISTS (SELECT 1 FROM json_each(sessions.tags) j WHERE lower(j.value) = lower(?))"); params.append(.text(tag)) }
        params.append(.int(Int64(limit)))
        return try db.query("SELECT * FROM sessions WHERE \(clauses.joined(separator: " AND ")) ORDER BY created_at DESC LIMIT ?", params).map(sessionRecord)
    }

    public func endSession(id: String) throws {
        try db.run("UPDATE sessions SET status = 'ended', ended_at = ? WHERE id = ? AND status = 'active'", [.date(Date()), .text(id)])
        if db.changes > 0 { addEvent(sessionId: id, kind: .sessionEnded, message: "Session ended", refId: id) }
    }

    /// Pauses or resumes steering for a session (checked on every decision, so it takes effect at once).
    public func setPaused(sessionId: String, _ paused: Bool) throws {
        try db.run("UPDATE sessions SET paused = ? WHERE id = ? AND paused != ?", [.int(paused ? 1 : 0), .text(sessionId), .int(paused ? 1 : 0)])
        if db.changes > 0 {
            addEvent(sessionId: sessionId, kind: .warning, message: paused ? "Steering paused: tool results reach Claude unchanged (redaction still applies)" : "Steering resumed", refId: sessionId)
        }
    }

    public func annotate(sessionId: String, _ a: SessionAnnotations) throws {
        if let name = a.name {
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !n.isEmpty else { throw StoreError("the session name is empty") }
            try db.run("UPDATE sessions SET name = ? WHERE id = ?", [.text(String(n.prefix(200))), .text(sessionId)])
        }
        if let notes = a.notes {
            guard notes.count <= SessionAnnotations.maxNotesLength else { throw StoreError("notes are limited to \(SessionAnnotations.maxNotesLength) characters") }
            try db.run("UPDATE sessions SET notes = ? WHERE id = ?", [.text(notes), .text(sessionId)])
        }
        if let tags = a.tags {
            try db.run("UPDATE sessions SET tags = ? WHERE id = ?", [.text(json(SessionAnnotations.normalizedTags(tags))), .text(sessionId)])
        }
    }

    /// Every tag in use, most used first.
    public func sessionTags() throws -> [String] {
        // Tags differing only in case are one tag.
        let rows = try db.query("SELECT MIN(j.value) AS tag, COUNT(*) AS n FROM sessions s, json_each(s.tags) j GROUP BY lower(j.value) ORDER BY n DESC, lower(j.value)")
        return rows.compactMap { $0.string("tag") }
    }

    /// Archives or unarchives sessions. Running sessions can't be archived. Returns how many changed.
    @discardableResult
    public func setArchived(sessionIds: [String], _ archived: Bool) throws -> Int {
        var n = 0
        try db.transaction {
            for id in sessionIds {
                try db.run("UPDATE sessions SET archived = ? WHERE id = ? AND archived != ?" + (archived ? " AND status != 'active'" : ""),
                           [.int(archived ? 1 : 0), .text(id), .int(archived ? 1 : 0)])
                n += db.changes
            }
        }
        return n
    }

    /// Ids of ended, unarchived sessions that started before `date` (bulk archiving).
    public func endedSessions(before date: Date, kind: SessionKind? = nil) throws -> [String] {
        var sql = "SELECT id FROM sessions WHERE archived = 0 AND status != 'active' AND created_at < ?"
        var params: [SQLValue] = [.date(date)]
        if let kind { sql += " AND kind = ?"; params.append(.text(kind.rawValue)) }
        return try db.query(sql, params).compactMap { $0.string("id") }
    }

    /// Switches one rule off (or back on) for one session. Emits a warning event so the timeline shows it.
    public func setRuleDisabled(sessionId: String, ruleId: String, _ disabled: Bool) throws {
        guard let s = try session(id: sessionId) else { throw StoreError("no session \(sessionId)") }
        var ids = s.disabledRules.filter { $0 != ruleId }
        if disabled { ids.append(ruleId) }
        guard ids != s.disabledRules else { return }
        try db.run("UPDATE sessions SET disabled_rules = ? WHERE id = ?", [.text(json(ids)), .text(sessionId)])
        let name = ruleId == "session-prompt" ? "the session prompt" : "“" + (s.profileVersion?.profile.rules.first { $0.id == ruleId }?.name ?? ruleId) + "”"
        addEvent(sessionId: sessionId, kind: .warning, message: disabled ? "Rule \(name) switched off for this session" : "Rule \(name) switched back on", refId: sessionId)
    }

    /// Current disabled rules (read fresh, since a session's record is loaded once per request).
    public func disabledRules(sessionId: String) -> [String] {
        let row = try? db.query("SELECT disabled_rules FROM sessions WHERE id = ?", [.text(sessionId)]).first
        return row.flatMap { decode([String].self, $0.string("disabled_rules")) } ?? []
    }

    public func isPaused(sessionId: String) -> Bool {
        ((try? db.query("SELECT paused FROM sessions WHERE id = ?", [.text(sessionId)]).first?.int("paused")) ?? 0) != 0
    }

    public func setTranscriptPath(sessionId: String, _ path: String) throws {
        try db.run("UPDATE sessions SET transcript_path = ? WHERE id = ? AND (transcript_path IS NULL OR transcript_path != ?)", [.text(path), .text(sessionId), .text(path)])
    }

    /// Reactivates an ended session (a resumed hook-mode session).
    public func reopenSession(id: String) throws {
        try db.run("UPDATE sessions SET status = 'active', ended_at = NULL WHERE id = ? AND status = 'ended'", [.text(id)])
        if db.changes > 0 { addEvent(sessionId: id, kind: .sessionCreated, message: "Session resumed", refId: id) }
    }

    public func recordClaudeSessionId(sessionId: String, claudeSessionId: String) throws {
        guard var rec = try session(id: sessionId), !rec.claudeSessionIds.contains(claudeSessionId) else { return }
        rec.claudeSessionIds.append(claudeSessionId)
        try db.run("UPDATE sessions SET claude_session_ids = ? WHERE id = ?", [.text(json(rec.claudeSessionIds)), .text(sessionId)])
    }

    public func addFlag(sessionId: String, _ flag: String) throws {
        guard var rec = try session(id: sessionId), !rec.flags.contains(flag) else { return }
        rec.flags.append(flag)
        try db.run("UPDATE sessions SET flags = ? WHERE id = ?", [.text(json(rec.flags)), .text(sessionId)])
    }

    public func stats(sessionId: String) throws -> SessionStats {
        var s = SessionStats()
        s.exchanges = Int(try db.query("SELECT COUNT(*) AS n FROM exchanges WHERE session_id = ?", [.text(sessionId)]).first?.int("n") ?? 0)
        for r in try db.query("SELECT outcome, COUNT(*) AS n FROM decisions WHERE session_id = ? GROUP BY outcome", [.text(sessionId)]) {
            let n = Int(r.int("n") ?? 0)
            s.toolResults += n
            switch r.string("outcome") {
            case "rewritten": s.rewrites += n
            case "failed": s.failures += n
            default: break
            }
        }
        s.anomalies = Int(try db.query("SELECT COUNT(*) AS n FROM events WHERE session_id = ? AND kind = 'anomaly'", [.text(sessionId)]).first?.int("n") ?? 0)
        s.rewriteCostUSD = try db.query("SELECT COALESCE(SUM(cost_usd), 0) AS c FROM rewrite_attempts WHERE session_id = ?", [.text(sessionId)]).first?.double("c") ?? 0
        return s
    }

    public func info(_ r: SessionRecord) throws -> SessionInfo {
        SessionInfo(
            id: r.id, name: r.name, cwd: r.cwd, kind: r.kind, status: r.status, createdAt: r.createdAt, endedAt: r.endedAt,
            profileId: r.profileId, profileName: r.profileVersion?.profile.name, profileVersionId: r.profileVersion?.id,
            profileVersionNumber: r.profileVersion?.number, prompt: r.prompt, lockdown: r.lockdown, trialId: r.trialId,
            claudeSessionIds: r.claudeSessionIds, flags: r.flags, stats: try stats(sessionId: r.id), via: r.via, paused: r.paused,
            notes: r.notes, tags: r.tags, archived: r.archived, disabledRules: r.disabledRules)
    }

    /// Marks sessions left `active` by a previous daemon whose Claude process is gone.
    public func activeSessionCount() -> Int {
        Int((try? db.query("SELECT COUNT(*) AS n FROM sessions WHERE status = 'active'").first?.int("n")) ?? 0)
    }

    // MARK: Exchanges

    public struct NewExchange: Sendable {
        public var sessionId: String
        public var method: String
        public var path: String
        public var requestClass: String?
        public var agentId: String?
        public var claudeSessionId: String?
        public var requestHeaders: [String: String]

        public init(sessionId: String, method: String, path: String, requestClass: String?, agentId: String?, claudeSessionId: String?, requestHeaders: [String: String]) {
            self.sessionId = sessionId
            self.method = method
            self.path = path
            self.requestClass = requestClass
            self.agentId = agentId
            self.claudeSessionId = claudeSessionId
            self.requestHeaders = requestHeaders
        }
    }

    public func beginExchange(_ e: NewExchange) throws -> Int64 {
        try db.run(
            """
            INSERT INTO exchanges(session_id, started_at, method, path, request_class, agent_id, claude_session_id, request_headers)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(e.sessionId), .date(Date()), .text(e.method), .text(e.path), .optional(e.requestClass), .optional(e.agentId),
                .optional(e.claudeSessionId), .text(json(e.requestHeaders)),
            ])
    }

    public struct ExchangeRequestInfo: Sendable {
        public var model: String?
        public var toolResults: [ToolResultEntry]
        public var requestBlob: String?
        public var forwardedBlob: String?
        public var addedLatencyMs: Double

        public init(model: String?, toolResults: [ToolResultEntry], requestBlob: String?, forwardedBlob: String?, addedLatencyMs: Double) {
            self.model = model
            self.toolResults = toolResults
            self.requestBlob = requestBlob
            self.forwardedBlob = forwardedBlob
            self.addedLatencyMs = addedLatencyMs
        }
    }

    public func recordRequest(exchangeId: Int64, _ info: ExchangeRequestInfo) throws {
        try db.run(
            "UPDATE exchanges SET model = ?, tool_results = ?, request_blob = ?, forwarded_blob = ?, added_ms = ? WHERE id = ?",
            [.optional(info.model), .text(json(info.toolResults)), .optional(info.requestBlob), .optional(info.forwardedBlob), .double(info.addedLatencyMs), .int(exchangeId)])
    }

    public struct ExchangeResponseInfo: Sendable {
        public var status: Int
        public var ttfbMs: Double?
        public var durationMs: Double
        public var usage: TokenUsage?
        public var assistant: AssistantSummary?
        public var error: String?
        public var responseBlob: String?
        public var responseHeaders: [String: String]

        public init(status: Int, ttfbMs: Double?, durationMs: Double, usage: TokenUsage?, assistant: AssistantSummary?, error: String?, responseBlob: String?, responseHeaders: [String: String]) {
            self.status = status
            self.ttfbMs = ttfbMs
            self.durationMs = durationMs
            self.usage = usage
            self.assistant = assistant
            self.error = error
            self.responseBlob = responseBlob
            self.responseHeaders = responseHeaders
        }
    }

    public func recordResponse(exchangeId: Int64, _ info: ExchangeResponseInfo) throws {
        try db.run(
            "UPDATE exchanges SET status = ?, ttfb_ms = ?, duration_ms = ?, usage = ?, assistant = ?, error = ?, response_blob = ?, response_headers = ? WHERE id = ?",
            [
                .int(Int64(info.status)), .optional(info.ttfbMs), .double(info.durationMs), info.usage.map { .text(json($0)) } ?? .null,
                info.assistant.map { .text(json($0)) } ?? .null, .optional(info.error), .optional(info.responseBlob),
                .text(json(info.responseHeaders)), .int(exchangeId),
            ])
    }

    func exchangeSummary(_ r: Row) -> ExchangeSummary {
        ExchangeSummary(
            id: r.int("id") ?? 0, sessionId: r.string("session_id") ?? "", startedAt: r.date("started_at") ?? Date(),
            method: r.string("method") ?? "", path: r.string("path") ?? "", requestClass: r.string("request_class"),
            agentId: r.string("agent_id"), claudeSessionId: r.string("claude_session_id"), model: r.string("model"),
            status: r.int("status").map(Int.init), timeToFirstByteMs: r.double("ttfb_ms"), addedLatencyMs: r.double("added_ms"),
            durationMs: r.double("duration_ms"), usage: decode(TokenUsage.self, r.string("usage")),
            toolResults: decode([ToolResultEntry].self, r.string("tool_results")) ?? [],
            assistant: decode(AssistantSummary.self, r.string("assistant")), error: r.string("error"))
    }

    public func exchanges(sessionId: String, afterId: Int64 = 0, limit: Int = 2000) throws -> [ExchangeSummary] {
        try db.query(
            "SELECT * FROM exchanges WHERE session_id = ? AND id > ? ORDER BY id LIMIT ?",
            [.text(sessionId), .int(afterId), .int(Int64(limit))]).map(exchangeSummary)
    }

    public func exchange(id: Int64) throws -> ExchangeSummary? {
        try db.query("SELECT * FROM exchanges WHERE id = ?", [.int(id)]).first.map(exchangeSummary)
    }

    public struct ExchangeRaw: Sendable {
        public var request: String?
        public var forwarded: String?
        public var response: String?
        public var requestHeaders: String?
        public var responseHeaders: String?
    }

    public func exchangeRaw(id: Int64) throws -> ExchangeRaw? {
        guard let r = try db.query("SELECT * FROM exchanges WHERE id = ?", [.int(id)]).first else { return nil }
        func load(_ col: String) -> String? { r.string(col).flatMap { try? blobs.getString($0) } }
        return ExchangeRaw(
            request: load("request_blob"), forwarded: load("forwarded_blob"), response: load("response_blob"),
            requestHeaders: r.string("request_headers"), responseHeaders: r.string("response_headers"))
    }
}
