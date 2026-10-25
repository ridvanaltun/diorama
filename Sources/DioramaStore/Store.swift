import DioramaCore
import Foundation

/// Persistent state: SQLite metadata plus a content-addressed blob store.
public final class Store: @unchecked Sendable {
    public let db: SQLiteDatabase
    public let blobs: BlobStore
    public let paths: DioramaPaths
    /// Called (outside any transaction) for every event recorded.
    public var onEvent: (@Sendable (SessionEvent) -> Void)?
    /// Set when the database had to be recovered at startup.
    public private(set) var recoveryNote: String?

    static let migrations: [String] = [
        // v1
        """
        CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE profiles(
          id TEXT PRIMARY KEY, name TEXT NOT NULL UNIQUE, current_version_id TEXT NOT NULL,
          created_at REAL NOT NULL, updated_at REAL NOT NULL, archived INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE profile_versions(
          id TEXT PRIMARY KEY, profile_id TEXT NOT NULL REFERENCES profiles(id), number INTEGER NOT NULL,
          body TEXT NOT NULL, created_at REAL NOT NULL, UNIQUE(profile_id, number));
        CREATE TABLE sessions(
          id TEXT PRIMARY KEY, token_hash TEXT NOT NULL UNIQUE, name TEXT NOT NULL, cwd TEXT NOT NULL,
          kind TEXT NOT NULL, status TEXT NOT NULL, created_at REAL NOT NULL, ended_at REAL,
          profile_id TEXT, profile_version_id TEXT, prompt TEXT, lockdown TEXT NOT NULL, trial_id TEXT,
          on_failure TEXT, treatment_scope TEXT, claude_session_ids TEXT NOT NULL DEFAULT '[]', flags TEXT NOT NULL DEFAULT '[]');
        CREATE TABLE exchanges(
          id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL, started_at REAL NOT NULL,
          method TEXT NOT NULL, path TEXT NOT NULL, request_class TEXT, agent_id TEXT, claude_session_id TEXT,
          model TEXT, status INTEGER, ttfb_ms REAL, added_ms REAL, duration_ms REAL, usage TEXT,
          tool_results TEXT NOT NULL DEFAULT '[]', assistant TEXT, error TEXT, request_blob TEXT,
          forwarded_blob TEXT, response_blob TEXT, request_headers TEXT, response_headers TEXT);
        CREATE INDEX exchanges_session ON exchanges(session_id, id);
        CREATE TABLE decisions(
          tool_use_id TEXT PRIMARY KEY, session_id TEXT NOT NULL, exchange_id INTEGER NOT NULL,
          tool_name TEXT, tool_input TEXT, is_error INTEGER NOT NULL DEFAULT 0, original_hash TEXT NOT NULL,
          original_blob TEXT NOT NULL, outcome TEXT NOT NULL, reason TEXT NOT NULL, replacement_blob TEXT,
          rules TEXT NOT NULL DEFAULT '[]', instructions TEXT NOT NULL DEFAULT '[]', created_at REAL NOT NULL,
          replay_count INTEGER NOT NULL DEFAULT 0, treatment_key TEXT);
        CREATE INDEX decisions_session ON decisions(session_id, created_at);
        CREATE TABLE rewrite_attempts(
          id TEXT PRIMARY KEY, tool_use_id TEXT NOT NULL, session_id TEXT, provider TEXT NOT NULL,
          model_requested TEXT NOT NULL, model_served TEXT, prompt_version TEXT NOT NULL, status TEXT NOT NULL,
          error TEXT, usage TEXT, cost_usd REAL, latency_ms REAL NOT NULL, explanation TEXT, mode TEXT,
          edits TEXT NOT NULL DEFAULT '[]', request_blob TEXT, response_blob TEXT, created_at REAL NOT NULL);
        CREATE INDEX attempts_tool ON rewrite_attempts(tool_use_id);
        CREATE TABLE treatment_cache(
          key TEXT PRIMARY KEY, replacement_blob TEXT NOT NULL, attempt_id TEXT, created_at REAL NOT NULL);
        CREATE TABLE events(
          id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, kind TEXT NOT NULL, message TEXT NOT NULL,
          ref_id TEXT, created_at REAL NOT NULL);
        CREATE INDEX events_session ON events(session_id, id);
        CREATE TABLE experiments(
          id TEXT PRIMARY KEY, name TEXT NOT NULL, definition TEXT NOT NULL, definition_hash TEXT NOT NULL,
          created_at REAL NOT NULL);
        CREATE TABLE runs(
          id TEXT PRIMARY KEY, experiment_id TEXT NOT NULL REFERENCES experiments(id), status TEXT NOT NULL,
          created_at REAL NOT NULL, started_at REAL, finished_at REAL, seed INTEGER NOT NULL, estimate TEXT,
          confirmation_token TEXT, trials_total INTEGER NOT NULL);
        CREATE TABLE trials(
          id TEXT PRIMARY KEY, run_id TEXT NOT NULL REFERENCES runs(id), variant_key TEXT NOT NULL,
          idx INTEGER NOT NULL, ord INTEGER NOT NULL, status TEXT NOT NULL, session_id TEXT, workdir TEXT,
          started_at REAL, finished_at REAL, manifest TEXT, facts TEXT, signals TEXT, error TEXT,
          transcript_blob TEXT);
        CREATE INDEX trials_run ON trials(run_id, ord);
        """,
        // v2: hook-mode sessions (Claude desktop, IDEs)
        """
        ALTER TABLE sessions ADD COLUMN via TEXT NOT NULL DEFAULT 'gateway';
        """,
        // v3: spending that has no rewrite attempt record (playground, what-if)
        """
        CREATE TABLE spend_ledger(
          id INTEGER PRIMARY KEY AUTOINCREMENT, created_at REAL NOT NULL, kind TEXT NOT NULL, profile_id TEXT, cost_usd REAL NOT NULL);
        CREATE INDEX spend_ledger_day ON spend_ledger(created_at);
        """,
    ]

    public static var schemaVersion: Int { migrations.count }

    public init(paths: DioramaPaths) throws {
        self.paths = paths
        try paths.ensureDirectories()
        blobs = try BlobStore(root: paths.blobs)
        let (db, note) = try Store.openRecovering(paths.database)
        self.db = db
        recoveryNote = note
        try migrate()
    }

    /// Opens the database; if it is unreadable or fails an integrity check, moves it aside
    /// (keeping it for inspection) and starts a fresh one.
    static func openRecovering(_ url: URL) throws -> (SQLiteDatabase, String?) {
        do {
            let db = try SQLiteDatabase(path: url.path)
            if db.quickCheck() { return (db, nil) }
            db.close()
        } catch {
            // fall through to recovery
        }
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = url.deletingLastPathComponent().appendingPathComponent("diorama.corrupt-\(stamp).sqlite")
        let fm = FileManager.default
        try? fm.moveItem(at: url, to: aside)
        for suffix in ["-wal", "-shm"] {
            try? fm.moveItem(atPath: url.path + suffix, toPath: aside.path + suffix)
        }
        let db = try SQLiteDatabase(path: url.path)
        return (db, "The database failed an integrity check and was moved to \(aside.lastPathComponent); a new one was created.")
    }

    func migrate() throws {
        let current = db.userVersion
        guard current < Store.migrations.count else {
            if current > Store.migrations.count {
                throw SQLiteError(code: -1, message: "database schema v\(current) is newer than this Diorama (v\(Store.migrations.count)); upgrade Diorama")
            }
            return
        }
        for v in current..<Store.migrations.count {
            try db.transaction {
                try db.execute(Store.migrations[v])
                try db.execute("PRAGMA user_version = \(v + 1)")
            }
        }
    }

    // MARK: - Helpers

    func json<T: Encodable>(_ value: T) -> String {
        (try? String(decoding: DioramaCoding.encoder.encode(value), as: UTF8.self)) ?? "null"
    }

    func decode<T: Decodable>(_ type: T.Type, _ text: String?) -> T? {
        guard let text, let data = text.data(using: .utf8) else { return nil }
        return try? DioramaCoding.decoder.decode(type, from: data)
    }

    // MARK: - Meta / settings

    public func meta(_ key: String) -> String? {
        (try? db.query("SELECT value FROM meta WHERE key = ?", [.text(key)]).first?.string("value")) ?? nil
    }

    public func setMeta(_ key: String, _ value: String) throws {
        try db.run("INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [.text(key), .text(value)])
    }

    public func settings() -> DioramaSettings {
        decode(DioramaSettings.self, meta("settings")) ?? DioramaSettings()
    }

    public func saveSettings(_ s: DioramaSettings) throws {
        try setMeta("settings", json(s))
    }

    // MARK: - Events

    @discardableResult
    public func addEvent(sessionId: String?, kind: SessionEvent.Kind, message: String, refId: String? = nil) -> SessionEvent? {
        let now = Date()
        guard let id = try? db.run(
            "INSERT INTO events(session_id, kind, message, ref_id, created_at) VALUES(?, ?, ?, ?, ?)",
            [.optional(sessionId), .text(kind.rawValue), .text(message), .optional(refId), .date(now)])
        else { return nil }
        let ev = SessionEvent(id: id, sessionId: sessionId, kind: kind, message: message, refId: refId, createdAt: now)
        onEvent?(ev)
        return ev
    }

    public func events(sessionId: String?, afterId: Int64 = 0, limit: Int = 500) throws -> [SessionEvent] {
        let rows: [Row]
        if let sessionId {
            rows = try db.query(
                "SELECT * FROM events WHERE session_id = ? AND id > ? ORDER BY id LIMIT ?",
                [.text(sessionId), .int(afterId), .int(Int64(limit))])
        } else {
            rows = try db.query("SELECT * FROM events WHERE id > ? ORDER BY id LIMIT ?", [.int(afterId), .int(Int64(limit))])
        }
        return rows.map(Store.event(from:))
    }

    static func event(from r: Row) -> SessionEvent {
        SessionEvent(
            id: r.int("id") ?? 0, sessionId: r.string("session_id"),
            kind: SessionEvent.Kind(rawValue: r.string("kind") ?? "") ?? .warning, message: r.string("message") ?? "",
            refId: r.string("ref_id"), createdAt: r.date("created_at") ?? Date())
    }

    // MARK: - Retention

    /// Drops raw request/response capture older than `days` and deletes unreferenced blobs.
    @discardableResult
    public func applyRetention(days: Int, now: Date = Date()) throws -> (cleared: Int, blobsRemoved: Int) {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        try db.run(
            "UPDATE exchanges SET request_blob = NULL, forwarded_blob = NULL, response_blob = NULL WHERE started_at < ? AND (request_blob IS NOT NULL OR response_blob IS NOT NULL)",
            [.date(cutoff)])
        let cleared = db.changes
        return (cleared, collectGarbage())
    }

    /// Mark-and-sweep over every blob reference in the database.
    @discardableResult
    public func collectGarbage(minAge: TimeInterval = 3600) -> Int {
        var keep = Set<String>()
        let refs: [(String, [String])] = [
            ("exchanges", ["request_blob", "forwarded_blob", "response_blob"]),
            ("decisions", ["original_blob", "replacement_blob"]),
            ("rewrite_attempts", ["request_blob", "response_blob"]),
            ("treatment_cache", ["replacement_blob"]),
            ("trials", ["transcript_blob"]),
        ]
        for (table, cols) in refs {
            for col in cols {
                if let rows = try? db.query("SELECT \(col) AS h FROM \(table) WHERE \(col) IS NOT NULL") {
                    for r in rows { if let h = r.string("h") { keep.insert(h) } }
                }
            }
        }
        return blobs.collectGarbage(keep: keep, minAge: minAge)
    }
}
