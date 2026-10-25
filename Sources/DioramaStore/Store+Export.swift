import DioramaCore
import Foundation

extension Store {
    /// Decided tool results matching `filter`, oldest first, flattened for analysis.
    public func exportDecisions(_ filter: DecisionExportFilter, limit: Int = 200_000) throws -> [DecisionExportRow] {
        var clauses = ["1 = 1"]
        var params: [SQLValue] = []
        if let since = filter.since { clauses.append("d.created_at >= ?"); params.append(.date(since)) }
        if let until = filter.until { clauses.append("d.created_at < ?"); params.append(.date(until)) }
        if let sid = filter.sessionId { clauses.append("d.session_id = ?"); params.append(.text(sid)) }
        if let pid = filter.profileId { clauses.append("s.profile_id = ?"); params.append(.text(pid)) }
        if !filter.includeTrials { clauses.append("s.trial_id IS NULL") }
        if filter.rewrittenOnly { clauses.append("d.outcome = 'rewritten'") }
        params.append(.int(Int64(limit)))
        let rows = try db.query(
            """
            SELECT d.*, s.name AS session_name, s.tags AS session_tags, s.kind AS session_kind, s.via AS via, s.trial_id AS trial_id,
                   p.name AS profile_name, v.number AS profile_number,
                   (SELECT COUNT(*) FROM rewrite_attempts a WHERE a.tool_use_id = d.tool_use_id) AS attempt_count,
                   (SELECT COALESCE(SUM(a.cost_usd), 0) FROM rewrite_attempts a WHERE a.tool_use_id = d.tool_use_id) AS cost
            FROM decisions d JOIN sessions s ON s.id = d.session_id
            LEFT JOIN profile_versions v ON v.id = s.profile_version_id
            LEFT JOIN profiles p ON p.id = s.profile_id
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY d.created_at LIMIT ?
            """, params)
        return rows.map { r in
            let d = decisionRecord(r)
            let tags = decode([String].self, r.string("session_tags")) ?? []
            // Stored as content JSON; export the readable text (as the decision detail shows it).
            let original = (try? blobs.getString(d.originalBlob)).map { ContentText.displayText(fromContentJSON: $0) }
            let replacement = d.replacementBlob.flatMap { try? blobs.getString($0) }.map { ContentText.displayText(fromContentJSON: $0) }
            let stage = d.toolUseId.hasPrefix("page:") ? "page" : d.toolUseId.hasPrefix("input:") ? "input" : "result"
            var row = DecisionExportRow(
                decisionId: d.toolUseId, createdAt: d.createdAt, sessionId: d.sessionId, sessionName: r.string("session_name") ?? "",
                sessionKind: r.string("session_kind") ?? "", via: r.string("via") ?? "gateway", trialId: r.string("trial_id"),
                profile: r.string("profile_name"), profileVersion: r.int("profile_number").map { Int($0) }, tool: d.toolName, stage: stage,
                toolInput: d.toolInput, isError: d.isError, outcome: d.outcome.rawValue, reason: d.reason, rules: d.rules.map(\.name),
                attempts: Int(r.int("attempt_count") ?? 0), costUSD: r.double("cost") ?? 0, originalChars: original?.count ?? 0,
                replacementChars: replacement?.count,
                originalText: filter.includeTexts ? original : nil, replacementText: filter.includeTexts ? replacement : nil)
            row.sessionTags = tags
            return row
        }
    }
}
