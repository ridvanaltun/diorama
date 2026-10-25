import DioramaCore
import Foundation

extension Store {
    /// Per-rule usage of a profile across all its versions (see `ProfileRuleStats`).
    public func ruleStats(profileId: String, since: Date?, includeTrials: Bool = false) throws -> ProfileRuleStats? {
        guard let current = try currentProfileVersion(profileId: profileId) else { return nil }
        let rows = try db.query(
            """
            SELECT d.tool_use_id, d.session_id, d.outcome, d.rules, d.instructions, d.created_at,
                   (SELECT COALESCE(SUM(a.cost_usd), 0) FROM rewrite_attempts a WHERE a.tool_use_id = d.tool_use_id) AS cost
            FROM decisions d JOIN sessions s ON s.id = d.session_id
            WHERE d.rules != '[]' AND d.created_at >= ?
              AND (? OR s.trial_id IS NULL)
              AND EXISTS (SELECT 1 FROM json_each(d.rules) j JOIN profile_versions v ON v.id = json_extract(j.value, '$.profileVersionId')
                          WHERE v.profile_id = ?)
            ORDER BY d.created_at
            """,
            [.date(since ?? Date(timeIntervalSince1970: 0)), .int(includeTrials ? 1 : 0), .text(profileId)])
        let versionIds = Set(try profileVersions(profileId: profileId).map(\.id))

        var uses: [String: ProfileRuleStats.RuleUse] = [:]
        for r in current.profile.rules { uses[r.id] = .init(ruleId: r.id, name: r.name, inCurrentVersion: true) }
        var sessions: [String: Set<String>] = [:]
        var total = 0.0
        for row in rows {
            let refs = (decode([RuleRef].self, row.string("rules")) ?? []).filter { $0.profileVersionId.map(versionIds.contains) ?? false }
            guard !refs.isEmpty else { continue }
            let all = decode([RuleRef].self, row.string("rules"))?.count ?? refs.count
            let instructions = decode([String].self, row.string("instructions")) ?? []
            let cost = row.double("cost") ?? 0
            let when = row.date("created_at")
            total += cost
            for ref in refs {
                var u = uses[ref.ruleId] ?? .init(ruleId: ref.ruleId, name: ref.name, inCurrentVersion: false)
                u.matched += 1
                switch DecisionOutcome(rawValue: row.string("outcome") ?? "") {
                case .rewritten: u.rewritten += 1
                case .failed: u.failed += 1
                default: u.unchanged += 1
                }
                if all > 1 { u.shared += 1 }
                if let verdict = Self.classifierVerdict(instructions, ruleName: ref.name) {
                    if verdict { u.classifierYes += 1 } else { u.classifierNo += 1 }
                }
                u.costUSD += cost
                u.lastMatchedAt = when
                if !u.inCurrentVersion { u.name = ref.name }
                uses[ref.ruleId] = u
                sessions[ref.ruleId, default: []].insert(row.string("session_id") ?? "")
            }
        }
        for (id, s) in sessions { uses[id]?.sessions = s.count }
        let order = current.profile.rules.map(\.id)
        let older = uses.values.filter { !$0.inCurrentVersion }.sorted { ($0.lastMatchedAt ?? .distantPast) > ($1.lastMatchedAt ?? .distantPast) }
        let name = try profiles(includeArchived: true).first { $0.id == profileId }?.name ?? current.profile.name
        return ProfileRuleStats(
            profileId: profileId, profileName: name, since: since, includesTrials: includeTrials, toolResults: rows.count, costUSD: total,
            rules: order.compactMap { uses[$0] } + older)
    }

    /// The classifier's answer recorded for one rule in a decision's instructions, if it had one
    /// (nil for no classifier; a failed classification counts as "no", as in the engine).
    static func classifierVerdict(_ instructions: [String], ruleName: String) -> Bool? {
        guard let line = instructions.first(where: { $0.hasPrefix("[\(ruleName)] Classifier “") }),
              let end = line.range(of: "”: ", options: .backwards)
        else { return nil }
        return line[end.upperBound...].hasPrefix("yes")
    }
}
