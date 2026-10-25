import DioramaCore
import Foundation

public struct StoreError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ d: String) { description = d }
}

extension Store {
    static func profileVersionId(profileId: String, body: String) -> String {
        "pv_" + Hashing.sha256Hex(profileId + "\n" + body).prefix(24)
    }

    func canonicalProfileBody(_ p: Profile) -> String { json(p) }

    public func validate(_ profile: Profile) -> [String] {
        var problems: [String] = []
        if profile.name.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("profile name is empty") }
        var ids = Set<String>()
        for r in profile.rules {
            if !ids.insert(r.id).inserted { problems.append("duplicate rule id \(r.id)") }
            if r.name.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("rule \(r.id) has no name") }
            if r.match.tools.isEmpty { problems.append("rule '\(r.name)' matches no tools") }
            if r.match.stage == .page, !r.match.tools.allSatisfy({ Glob.matches($0, "WebFetch") }) {
                problems.append("rule '\(r.name)': the page stage applies only to WebFetch (tools must match WebFetch)")
            }
            if let c = r.match.classifier {
                if c.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { problems.append("rule '\(r.name)': the classifier has no question") }
                if r.redact != nil { problems.append("rule '\(r.name)': redaction rules can't use a classifier") }
            }
            if let spec = r.redact {
                if spec.presets.isEmpty && spec.patterns.isEmpty { problems.append("rule '\(r.name)' redacts nothing (no presets or patterns)") }
                for p in spec.patterns where (try? NSRegularExpression(pattern: p)) == nil {
                    problems.append("rule '\(r.name)': invalid redaction pattern '\(p)'")
                }
            } else if r.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                problems.append("rule '\(r.name)' has empty instructions")
            }
            for (field, pattern) in r.match.input where (try? Regex(pattern)) == nil {
                problems.append("rule '\(r.name)': invalid regex for input field '\(field)'")
            }
            if let c = r.match.content, (try? Regex(c)) == nil { problems.append("rule '\(r.name)': invalid content regex") }
        }
        return problems
    }

    @discardableResult
    public func createProfile(_ profile: Profile) throws -> ProfileVersionInfo {
        let problems = validate(profile)
        guard problems.isEmpty else { throw StoreError(problems.joined(separator: "; ")) }
        if try db.query("SELECT id FROM profiles WHERE name = ? AND archived = 0", [.text(profile.name)]).first != nil {
            throw StoreError("a profile named '\(profile.name)' already exists")
        }
        // An archived profile with the same name is renamed out of the way.
        try db.run("UPDATE profiles SET name = name || ' (archived ' || id || ')' WHERE name = ? AND archived = 1", [.text(profile.name)])
        let id = Hashing.newId(prefix: "prof")
        let body = canonicalProfileBody(profile)
        let vid = Store.profileVersionId(profileId: id, body: body)
        let now = Date()
        try db.transaction {
            try db.run(
                "INSERT INTO profiles(id, name, current_version_id, created_at, updated_at) VALUES(?, ?, ?, ?, ?)",
                [.text(id), .text(profile.name), .text(vid), .date(now), .date(now)])
            try db.run(
                "INSERT INTO profile_versions(id, profile_id, number, body, created_at) VALUES(?, ?, 1, ?, ?)",
                [.text(vid), .text(id), .text(body), .date(now)])
        }
        addEvent(sessionId: nil, kind: .profileUpdated, message: "Created profile '\(profile.name)'", refId: id)
        return ProfileVersionInfo(id: vid, profileId: id, number: 1, createdAt: now, profile: profile)
    }

    /// Saves a new immutable version (no-op if the content is unchanged).
    @discardableResult
    public func updateProfile(id: String, _ profile: Profile) throws -> ProfileVersionInfo {
        let problems = validate(profile)
        guard problems.isEmpty else { throw StoreError(problems.joined(separator: "; ")) }
        guard let current = try currentProfileVersion(profileId: id) else { throw StoreError("unknown profile \(id)") }
        let body = canonicalProfileBody(profile)
        let vid = Store.profileVersionId(profileId: id, body: body)
        if vid == current.id { return current }
        if let clash = try db.query("SELECT id FROM profiles WHERE name = ? AND id != ? AND archived = 0", [.text(profile.name), .text(id)]).first,
           clash.string("id") != nil {
            throw StoreError("a profile named '\(profile.name)' already exists")
        }
        let now = Date()
        // Re-saving a body identical to an older version reuses that version.
        if let existing = try profileVersion(id: vid) {
            try db.run("UPDATE profiles SET current_version_id = ?, name = ?, updated_at = ? WHERE id = ?",
                       [.text(vid), .text(profile.name), .date(now), .text(id)])
            return existing
        }
        let number = current.number + 1
        try db.transaction {
            try db.run(
                "INSERT INTO profile_versions(id, profile_id, number, body, created_at) VALUES(?, ?, ?, ?, ?)",
                [.text(vid), .text(id), .int(Int64(number)), .text(body), .date(now)])
            try db.run("UPDATE profiles SET current_version_id = ?, name = ?, updated_at = ? WHERE id = ?",
                       [.text(vid), .text(profile.name), .date(now), .text(id)])
        }
        addEvent(sessionId: nil, kind: .profileUpdated, message: "Saved '\(profile.name)' v\(number)", refId: id)
        return ProfileVersionInfo(id: vid, profileId: id, number: number, createdAt: now, profile: profile)
    }

    public func archiveProfile(id: String) throws {
        try db.run("UPDATE profiles SET archived = 1, updated_at = ? WHERE id = ?", [.date(Date()), .text(id)])
    }

    public func profileVersion(id: String) throws -> ProfileVersionInfo? {
        guard let r = try db.query("SELECT * FROM profile_versions WHERE id = ?", [.text(id)]).first else { return nil }
        return versionInfo(r)
    }

    func versionInfo(_ r: Row) -> ProfileVersionInfo? {
        guard let p = decode(Profile.self, r.string("body")) else { return nil }
        return ProfileVersionInfo(
            id: r.string("id") ?? "", profileId: r.string("profile_id") ?? "", number: Int(r.int("number") ?? 0),
            createdAt: r.date("created_at") ?? Date(), profile: p)
    }

    public func currentProfileVersion(profileId: String) throws -> ProfileVersionInfo? {
        guard let r = try db.query(
            "SELECT v.* FROM profiles p JOIN profile_versions v ON v.id = p.current_version_id WHERE p.id = ?",
            [.text(profileId)]).first
        else { return nil }
        return versionInfo(r)
    }

    /// Resolves a profile by id or (non-archived) name to its current version.
    /// A profile's current version by id or name, or one specific version by its id (`pv_…`).
    public func resolveProfile(_ idOrName: String) throws -> ProfileVersionInfo? {
        if idOrName.hasPrefix("pv_") { return try profileVersion(id: idOrName) }
        if let v = try currentProfileVersion(profileId: idOrName) { return v }
        guard let r = try db.query("SELECT id FROM profiles WHERE name = ? AND archived = 0", [.text(idOrName)]).first,
              let id = r.string("id")
        else { return nil }
        return try currentProfileVersion(profileId: id)
    }

    public func profileVersions(profileId: String) throws -> [ProfileVersionInfo] {
        try db.query("SELECT * FROM profile_versions WHERE profile_id = ? ORDER BY number DESC", [.text(profileId)]).compactMap(versionInfo)
    }

    public func profiles(includeArchived: Bool = false) throws -> [ProfileSummary] {
        let rows = try db.query(
            """
            SELECT p.id, p.name, p.current_version_id, p.updated_at, v.number, v.body
            FROM profiles p JOIN profile_versions v ON v.id = p.current_version_id
            \(includeArchived ? "" : "WHERE p.archived = 0") ORDER BY p.name
            """)
        return rows.map { r in
            ProfileSummary(
                id: r.string("id") ?? "", name: r.string("name") ?? "", currentVersionId: r.string("current_version_id") ?? "",
                currentVersionNumber: Int(r.int("number") ?? 0),
                ruleCount: decode(Profile.self, r.string("body"))?.rules.count ?? 0, updatedAt: r.date("updated_at") ?? Date())
        }
    }
}
