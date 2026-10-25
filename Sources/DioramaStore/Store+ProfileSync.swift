import DioramaCore
import Foundation

/// Profile folders: profile JSON files in watched folders become profiles, and a changed file
/// becomes a new version (one way, file → Diorama). A deleted file leaves its profile alone.
private let profileSyncLock = NSLock()

extension Store {
    static let syncMaxDepth = 3
    static let syncSkippedFolders: Set<String> = ["node_modules", ".git", ".build", "build", "dist", "DerivedData"]

    /// JSON files under `folder` (a few levels deep, skipping hidden and build folders).
    static func profileFiles(in folder: String) -> [String] {
        let root = URL(fileURLWithPath: folder)
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var out: [String] = []
        for case let url as URL in e {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if syncSkippedFolders.contains(url.lastPathComponent) || e.level >= syncMaxDepth { e.skipDescendants() }
                continue
            }
            // (Not standardizedFileURL: it turns /private/var into /var, so paths would stop matching the folder.)
            if url.pathExtension.lowercased() == "json" { out.append(url.path) }
        }
        return out.sorted()
    }

    /// A profile from file contents, or nil if the file isn't a profile (it needs "name" and
    /// "rules"; a saved version's {"profile": …} works too).
    static func profile(fromFile data: Data) throws -> Profile? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StoreError("not valid JSON")
        }
        let body = (obj["profile"] as? [String: Any]) ?? obj
        guard body["name"] is String, body["rules"] is [Any] else { return nil }
        let json = try JSONSerialization.data(withJSONObject: body)
        do { return try DioramaCoding.decoder.decode(Profile.self, from: json) } catch { throw StoreError("not a valid profile: \(error)") }
    }

    /// Syncs every profile file in `folders` whose contents changed since the last pass.
    @discardableResult
    public func syncProfileFolders(_ folders: [String]) -> [ProfileFolderStatus] {
        // One pass at a time (the background poll and "sync now" can overlap).
        profileSyncLock.withLock {
            for folder in folders {
                for path in Self.profileFiles(in: folder) { syncProfileFile(path) }
            }
        }
        return profileFolderStatus(folders)
    }

    func syncProfileFile(_ path: String) {
        let record = try? db.query("SELECT * FROM profile_sync WHERE path = ?", [.text(path)]).first
        let mtime = ((try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date)?.timeIntervalSince1970 ?? 0
        // Unchanged since the last pass (files that failed are retried).
        if let r = record, r.double("mtime") == mtime, r.string("error") == nil { return }
        func save(_ profileId: String?, hash: String?, error: String?) {
            try? db.run(
                "INSERT OR REPLACE INTO profile_sync(path, profile_id, body_hash, mtime, error, synced_at) VALUES(?, ?, ?, ?, ?, ?)",
                [.text(path), .optional(profileId ?? record?.string("profile_id")), .optional(hash ?? record?.string("body_hash")), .double(mtime),
                 .optional(error), .date(Date())])
        }
        guard let data = FileManager.default.contents(atPath: path) else { return save(nil, hash: nil, error: "can't read the file") }
        let hash = Hashing.sha256Hex(data)
        if record?.string("body_hash") == hash, record?.string("error") == nil { return save(nil, hash: hash, error: nil) }
        let profile: Profile
        do {
            guard let p = try Self.profile(fromFile: data) else {
                // Not a profile (e.g. package.json): forget it quietly.
                try? db.run("DELETE FROM profile_sync WHERE path = ?", [.text(path)])
                return
            }
            profile = p
        } catch {
            return save(nil, hash: hash, error: "\(error)")
        }
        let problems = validate(profile)
        guard problems.isEmpty else { return save(nil, hash: hash, error: problems.joined(separator: "; ")) }
        do {
            // The profile this file made before, if it still exists; else one with the same name that no other file owns.
            var target = record?.string("profile_id").flatMap { id in (try? profiles())?.first { $0.id == id } }
            if target == nil, let byName = try profiles().first(where: { $0.name == profile.name }) {
                if let owner = try db.query("SELECT path FROM profile_sync WHERE profile_id = ? AND path != ?", [.text(byName.id), .text(path)]).first?.string("path") {
                    return save(nil, hash: hash, error: "the profile “\(profile.name)” is already synced from \(owner)")
                }
                target = byName
            }
            let id: String
            if let t = target {
                id = try updateProfile(id: t.id, profile).profileId
            } else {
                id = try createProfile(profile).profileId
            }
            save(id, hash: hash, error: nil)
        } catch {
            save(nil, hash: hash, error: "\(error)")
        }
    }

    public func profileFolderStatus(_ folders: [String]) -> [ProfileFolderStatus] {
        let rows = (try? db.query("SELECT * FROM profile_sync ORDER BY path")) ?? []
        let names = Dictionary(((try? profiles()) ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        return folders.map { folder in
            let prefix = folder.hasSuffix("/") ? folder : folder + "/"
            let files = rows.filter { ($0.string("path") ?? "").hasPrefix(prefix) }.map { r in
                let path = r.string("path") ?? ""
                return ProfileSyncFile(path: path, profileId: r.string("profile_id"), profileName: r.string("profile_id").flatMap { names[$0] },
                                       error: r.string("error"), syncedAt: r.date("synced_at") ?? Date(), missing: !FileManager.default.fileExists(atPath: path))
            }
            return ProfileFolderStatus(path: folder, exists: FileManager.default.fileExists(atPath: folder), files: files)
        }
    }

    /// The file a profile is synced from, if any.
    public func syncedFile(profileId: String) -> String? {
        try? db.query("SELECT path FROM profile_sync WHERE profile_id = ? ORDER BY synced_at DESC", [.text(profileId)]).first?.string("path")
    }

    /// Writes a profile's current version to its synced file and records it as in sync (no new version follows).
    public func writeProfileToFile(profileId: String) throws -> String {
        guard let path = syncedFile(profileId: profileId) else { throw StoreError("this profile isn't synced from a file") }
        guard let v = try currentProfileVersion(profileId: profileId) else { throw StoreError("unknown profile \(profileId)") }
        let data = try DioramaCoding.prettyEncoder.encode(v.profile)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        let mtime = ((try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date)?.timeIntervalSince1970 ?? 0
        try db.run("UPDATE profile_sync SET body_hash = ?, mtime = ?, error = NULL, synced_at = ? WHERE path = ?",
                   [.text(Hashing.sha256Hex(data)), .double(mtime), .date(Date()), .text(path)])
        return path
    }
}
