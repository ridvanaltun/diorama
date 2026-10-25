import DioramaCore
import Foundation

extension Store {
    // MARK: Spending (budget guard)

    /// Records rewrite-agent spending that has no attempt record (playground, what-if).
    public func recordSpend(kind: String, profileId: String?, costUSD: Double) {
        guard costUSD > 0 else { return }
        try? db.run("INSERT INTO spend_ledger(created_at, kind, profile_id, cost_usd) VALUES(?, ?, ?, ?)",
                    [.date(Date()), .text(kind), .optional(profileId), .double(costUSD)])
    }

    /// Rewrite-agent spending since `start`: interactive sessions' attempts plus the ledger.
    /// Experiment trials don't count (they run against their own approved estimate).
    public func spend(since start: Date, profileId: String? = nil) -> Double {
        var attempts = """
            SELECT COALESCE(SUM(a.cost_usd), 0) AS c FROM rewrite_attempts a JOIN sessions s ON s.id = a.session_id
            WHERE a.created_at >= ? AND s.trial_id IS NULL
            """
        var ledger = "SELECT COALESCE(SUM(cost_usd), 0) AS c FROM spend_ledger WHERE created_at >= ?"
        var args: [SQLValue] = [.date(start)]
        if let profileId {
            attempts += " AND s.profile_id = ?"
            ledger += " AND profile_id = ?"
            args.append(.text(profileId))
        }
        let a = (try? db.query(attempts, args).first?.double("c")) ?? 0
        let l = (try? db.query(ledger, args).first?.double("c")) ?? 0
        return (a ?? 0) + (l ?? 0)
    }

    /// Spending since `start` per profile, for profiles that spent anything.
    public func spendByProfile(since start: Date) -> [String: Double] {
        var out: [String: Double] = [:]
        let rows = (try? db.query("""
            SELECT s.profile_id AS p, SUM(a.cost_usd) AS c FROM rewrite_attempts a JOIN sessions s ON s.id = a.session_id
            WHERE a.created_at >= ? AND s.trial_id IS NULL AND s.profile_id IS NOT NULL GROUP BY s.profile_id
            UNION ALL
            SELECT profile_id AS p, SUM(cost_usd) AS c FROM spend_ledger WHERE created_at >= ? AND profile_id IS NOT NULL GROUP BY profile_id
            """, [.date(start), .date(start)])) ?? []
        for r in rows {
            if let p = r.string("p") { out[p, default: 0] += r.double("c") ?? 0 }
        }
        return out
    }

    /// Spending per local day for the last `days` days (today included).
    public func spendHistory(days: Int, calendar: Calendar = .current, now: Date = Date()) throws -> SpendHistory {
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -(max(days, 1) - 1), to: today) else { return SpendHistory(days: []) }
        var byDay: [Date: SpendHistory.Day] = [:]
        var d = start
        while d <= today {
            byDay[d] = SpendHistory.Day(day: d)
            d = calendar.date(byAdding: .day, value: 1, to: d) ?? today.addingTimeInterval(86_400)
        }
        let names = Dictionary(try profiles(includeArchived: true).map { ($0.id, $0.name) }, uniquingKeysWith: { x, _ in x })
        let attempts = try db.query("""
            SELECT a.created_at AS t, COALESCE(a.cost_usd, 0) AS c, s.trial_id AS trial, s.profile_id AS p
            FROM rewrite_attempts a JOIN sessions s ON s.id = a.session_id WHERE a.created_at >= ?
            """, [.date(start)])
        for r in attempts {
            guard let t = r.date("t"), var day = byDay[calendar.startOfDay(for: t)] else { continue }
            let c = r.double("c") ?? 0
            if r.string("trial") != nil { day.trialsUSD += c } else { day.sessionsUSD += c }
            day.calls += 1
            if let p = r.string("p"), c > 0 { day.byProfile[names[p] ?? p, default: 0] += c }
            byDay[day.day] = day
        }
        for r in try db.query("SELECT created_at AS t, cost_usd AS c, profile_id AS p FROM spend_ledger WHERE created_at >= ?", [.date(start)]) {
            guard let t = r.date("t"), var day = byDay[calendar.startOfDay(for: t)] else { continue }
            let c = r.double("c") ?? 0
            day.previewsUSD += c
            if let p = r.string("p"), c > 0 { day.byProfile[names[p] ?? p, default: 0] += c }
            byDay[day.day] = day
        }
        return SpendHistory(days: byDay.values.sorted { $0.day < $1.day })
    }
}
