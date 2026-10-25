import DioramaCore
import Foundation

extension Store {
    // MARK: Full-text search

    /// Longest text indexed per field; search is for finding things, not storing them.
    static let searchFieldLimit = 100_000

    public func isIndexed(kind: SearchHit.Kind, ref: String) -> Bool {
        ((try? db.query("SELECT 1 AS x FROM search_indexed WHERE kind = ? AND ref = ?", [.text(kind.rawValue), .text(ref)]).first) ?? nil) != nil
    }

    /// Adds one document to the index (once per kind and ref).
    public func index(kind: SearchHit.Kind, ref: String, sessionId: String, createdAt: Date, outcome: DecisionOutcome?,
                      tool: String?, input: String?, original: String?, rewritten: String?, note: String?) {
        guard !isIndexed(kind: kind, ref: ref) else { return }
        func clip(_ s: String?) -> SQLValue { s.map { .text(String($0.prefix(Self.searchFieldLimit))) } ?? .null }
        try? db.transaction {
            try db.run(
                """
                INSERT INTO search_docs(kind, ref, session_id, created_at, outcome, tool, input, original, rewritten, note)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [.text(kind.rawValue), .text(ref), .text(sessionId), .date(createdAt), .optional(outcome?.rawValue), clip(tool), clip(input), clip(original), clip(rewritten), clip(note)])
            try db.run("INSERT OR IGNORE INTO search_indexed(kind, ref) VALUES(?, ?)", [.text(kind.rawValue), .text(ref)])
        }
    }

    /// Records that a ref needs no document (nothing searchable), so backfilling skips it.
    public func markIndexed(kind: SearchHit.Kind, ref: String) {
        try? db.run("INSERT OR IGNORE INTO search_indexed(kind, ref) VALUES(?, ?)", [.text(kind.rawValue), .text(ref)])
    }

    /// Decisions and exchanges with replies that aren't in the index yet (for backfilling).
    public func unindexed(limit: Int = 500) throws -> (decisions: [String], exchanges: [Int64]) {
        let d = try db.query(
            "SELECT tool_use_id FROM decisions WHERE tool_use_id NOT IN (SELECT ref FROM search_indexed WHERE kind = 'decision') LIMIT ?",
            [.int(Int64(limit))]).compactMap { $0.string("tool_use_id") }
        let e = try db.query(
            "SELECT id FROM exchanges WHERE assistant IS NOT NULL AND CAST(id AS TEXT) NOT IN (SELECT ref FROM search_indexed WHERE kind = 'reply') LIMIT ?",
            [.int(Int64(limit))]).compactMap { $0.int("id") }
        return (d, e)
    }

    /// Words from the user become quoted terms (all must match; the last one may be a prefix), so
    /// FTS syntax in the input can't cause errors.
    public static func searchExpression(_ query: String) -> String? {
        let terms = query.split(whereSeparator: \.isWhitespace).map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        guard var expr = terms.isEmpty ? nil : terms else { return nil }
        // The last word (2+ letters; the count includes its quotes) also matches as a prefix, for typing.
        if let last = expr.last, last.count >= 4 { expr[expr.count - 1] = last + "*" }
        return expr.joined(separator: " ")
    }

    /// Best matches first. `rewrittenOnly` keeps decisions Diorama changed; `sessionId` limits to one session.
    public func search(_ query: String, rewrittenOnly: Bool = false, sessionId: String? = nil, limit: Int = 50) throws -> [SearchHit] {
        guard let expr = Self.searchExpression(query) else { return [] }
        var sql = """
            SELECT kind, ref, session_id, created_at, outcome, tool, snippet(search_docs, -1, '⟦', '⟧', '…', 14) AS snip
            FROM search_docs WHERE search_docs MATCH ?
            """
        var args: [SQLValue] = [.text(expr)]
        if rewrittenOnly { sql += " AND outcome = 'rewritten'" }
        if let sessionId {
            sql += " AND session_id = ?"
            args.append(.text(sessionId))
        }
        sql += " ORDER BY bm25(search_docs, 2.0, 1.0, 1.0, 1.0, 0.5) LIMIT ?"
        args.append(.int(Int64(limit)))
        let rows = try db.query(sql, args)
        var names: [String: String] = [:]
        return rows.compactMap { r in
            guard let kind = r.string("kind").flatMap(SearchHit.Kind.init(rawValue:)), let ref = r.string("ref"), let sid = r.string("session_id") else { return nil }
            if names[sid] == nil { names[sid] = (try? session(id: sid))??.name ?? sid }
            return SearchHit(kind: kind, ref: ref, sessionId: sid, sessionName: names[sid] ?? sid, createdAt: r.date("created_at") ?? Date(),
                             toolName: kind == .decision ? r.string("tool") : nil, outcome: r.string("outcome").flatMap(DecisionOutcome.init(rawValue:)),
                             snippet: r.string("snip") ?? "")
        }
    }
}
