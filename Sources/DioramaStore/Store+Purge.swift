import DioramaCore
import Foundation

extension Store {
    // MARK: Storage

    public func storageUsage() throws -> StorageUsage {
        func count(_ sql: String) throws -> Int { Int(try db.query(sql).first?.int("n") ?? 0) }
        return StorageUsage(
            databaseBytes: databaseBytes(), blobBytes: blobs.totalBytes(),
            sessions: try count("SELECT COUNT(*) AS n FROM sessions WHERE trial_id IS NULL"),
            archivedSessions: try count("SELECT COUNT(*) AS n FROM sessions WHERE trial_id IS NULL AND archived = 1"),
            experiments: try count("SELECT COUNT(*) AS n FROM experiments"),
            archivedExperiments: try count("SELECT COUNT(*) AS n FROM experiments WHERE archived = 1"),
            decisions: try count("SELECT COUNT(*) AS n FROM decisions"),
            exchanges: try count("SELECT COUNT(*) AS n FROM exchanges"))
    }

    // MARK: Purge

    /// Permanently deletes archived sessions and archived experiments created more than `days` ago,
    /// with everything recorded for them: exchanges, decisions, rewrite attempts, events, search
    /// entries, and an experiment's runs, trials, trial sessions and run folders. Rewrite costs move
    /// to the spend ledger first, so spending history keeps its totals. Running sessions and
    /// experiments with a run in progress are never touched. Unreferenced blobs are then removed.
    public func purgeArchived(olderThanDays days: Int, dryRun: Bool, now: Date = Date(), blobMinAge: TimeInterval = 3600) throws -> PurgeResult {
        let cutoff = now.addingTimeInterval(-Double(max(days, 1)) * 86_400)
        let sessionIds = try db.query(
            "SELECT id FROM sessions WHERE archived = 1 AND status != 'active' AND trial_id IS NULL AND created_at < ?", [.date(cutoff)]
        ).compactMap { $0.string("id") }
        let experimentIds = try db.query(
            """
            SELECT id FROM experiments e WHERE archived = 1 AND created_at < ?
            AND NOT EXISTS (SELECT 1 FROM runs r WHERE r.experiment_id = e.id AND r.status = 'running')
            """, [.date(cutoff)]
        ).compactMap { $0.string("id") }

        try db.execute("CREATE TEMP TABLE IF NOT EXISTS purge_sessions(id TEXT PRIMARY KEY); CREATE TEMP TABLE IF NOT EXISTS purge_experiments(id TEXT PRIMARY KEY)")
        try db.execute("DELETE FROM purge_sessions; DELETE FROM purge_experiments")
        defer { try? db.execute("DELETE FROM purge_sessions; DELETE FROM purge_experiments") }
        for id in experimentIds { try db.run("INSERT OR IGNORE INTO purge_experiments(id) VALUES(?)", [.text(id)]) }
        let trialSessionIds = try db.query(
            """
            SELECT t.session_id AS id FROM trials t JOIN runs r ON r.id = t.run_id
            WHERE r.experiment_id IN (SELECT id FROM purge_experiments) AND t.session_id IS NOT NULL
            """
        ).compactMap { $0.string("id") }
        for id in sessionIds + trialSessionIds { try db.run("INSERT OR IGNORE INTO purge_sessions(id) VALUES(?)", [.text(id)]) }
        let runIds = try db.query("SELECT id FROM runs WHERE experiment_id IN (SELECT id FROM purge_experiments)").compactMap { $0.string("id") }

        func count(_ sql: String) throws -> Int { Int(try db.query(sql).first?.int("n") ?? 0) }
        var result = PurgeResult(
            dryRun: dryRun, sessions: sessionIds.count, experiments: experimentIds.count, runs: runIds.count,
            trialSessions: Set(trialSessionIds).count,
            decisions: try count("SELECT COUNT(*) AS n FROM decisions WHERE session_id IN (SELECT id FROM purge_sessions)"),
            exchanges: try count("SELECT COUNT(*) AS n FROM exchanges WHERE session_id IN (SELECT id FROM purge_sessions)"))
        guard !dryRun, !result.isEmpty else { return result }

        let before = blobs.totalBytes() + databaseBytes()
        try db.transaction {
            let inSessions = "(SELECT id FROM purge_sessions)"
            // Keep spending history: each attempt's cost becomes a ledger entry on the same day.
            try db.run(
                """
                INSERT INTO spend_ledger(created_at, kind, profile_id, cost_usd)
                SELECT a.created_at, CASE WHEN s.trial_id IS NULL THEN '\(Self.purgedSessionSpend)' ELSE '\(Self.purgedTrialSpend)' END, s.profile_id, a.cost_usd
                FROM rewrite_attempts a JOIN sessions s ON s.id = a.session_id
                WHERE a.session_id IN \(inSessions) AND a.cost_usd > 0
                """)
            try db.run("DELETE FROM search_indexed WHERE kind = 'decision' AND ref IN (SELECT tool_use_id FROM decisions WHERE session_id IN \(inSessions))")
            try db.run("DELETE FROM search_indexed WHERE kind = 'reply' AND ref IN (SELECT CAST(id AS TEXT) FROM exchanges WHERE session_id IN \(inSessions))")
            try db.run("DELETE FROM search_docs WHERE session_id IN \(inSessions)")
            try db.run("DELETE FROM rewrite_attempts WHERE session_id IN \(inSessions) OR tool_use_id IN (SELECT tool_use_id FROM decisions WHERE session_id IN \(inSessions))")
            try db.run("DELETE FROM decisions WHERE session_id IN \(inSessions)")
            try db.run("DELETE FROM exchanges WHERE session_id IN \(inSessions)")
            try db.run("DELETE FROM events WHERE session_id IN \(inSessions)")
            try db.run("DELETE FROM sessions WHERE id IN \(inSessions)")
            try db.run("DELETE FROM trials WHERE run_id IN (SELECT id FROM runs WHERE experiment_id IN (SELECT id FROM purge_experiments))")
            try db.run("DELETE FROM runs WHERE experiment_id IN (SELECT id FROM purge_experiments)")
            try db.run("DELETE FROM experiments WHERE id IN (SELECT id FROM purge_experiments)")
        }
        for id in runIds { try? FileManager.default.removeItem(at: paths.runs.appendingPathComponent(id)) }
        result.blobsRemoved = collectGarbage(minAge: blobMinAge)
        // Give the space back to the file system.
        try? db.execute("PRAGMA wal_checkpoint(TRUNCATE); VACUUM")
        result.bytesFreed = max(0, before - blobs.totalBytes() - databaseBytes())
        addEvent(sessionId: nil, kind: .warning,
                 message: "Permanently deleted \(result.sessions) archived session(s) and \(result.experiments) archived experiment(s) older than \(days) days")
        return result
    }

    /// Spend-ledger kinds for rewrite costs kept from purged sessions and trials.
    static let purgedSessionSpend = "purged-session"
    static let purgedTrialSpend = "purged-trial"

    func databaseBytes() -> Int64 {
        ["", "-wal"].reduce(Int64(0)) { sum, suffix in
            sum + ((try? FileManager.default.attributesOfItem(atPath: paths.database.path + suffix)[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }
}
