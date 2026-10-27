import DioramaCore
import Foundation

/// One session as a zip for sharing or archiving: reports, every decision with its texts, the
/// exact profile version, session metadata, and a manifest of SHA-256 hashes. Built from the
/// control API; never includes keys or Claude Code's credentials (Diorama doesn't store them).
public enum AuditBundle {
    public struct Manifest: Codable, Sendable {
        public var sessionId: String
        public var sessionName: String
        public var generatedAt: Date
        public var dioramaVersion: String
        public var rewritePromptVersion: String
        /// File name → SHA-256 of its bytes.
        public var files: [String: String]
    }

    /// Writes the bundle to `zip` (replacing it). Returns the manifest.
    @discardableResult
    public static func write(client: ControlClient, sessionId: String, to zip: URL) async throws -> Manifest {
        let timeline = try await client.timeline(sessionId)
        let s = timeline.session
        var files: [String: Data] = [:]
        files["report.html"] = Data(try await client.sessionReport(sessionId, format: "html").utf8)
        files["report.md"] = Data(try await client.sessionReport(sessionId, format: "md").utf8)
        files["decisions.jsonl"] = Data(try await client.exportDecisions(format: .jsonl, sessionId: sessionId, includeTexts: true).content.utf8)
        files["session.json"] = try DioramaCoding.prettyEncoder.encode(s)
        files["timeline.json"] = try DioramaCoding.prettyEncoder.encode(timeline)
        if let pid = s.profileId, let vid = s.profileVersionId,
           let v = try await client.profile(pid).versions.first(where: { $0.id == vid }) {
            files["profile.json"] = try DioramaCoding.prettyEncoder.encode(v)
        }
        let manifest = Manifest(sessionId: s.id, sessionName: s.name, generatedAt: Date(), dioramaVersion: DioramaVersion.current,
                                rewritePromptVersion: DioramaVersion.rewritePromptVersion,
                                files: files.mapValues { Hashing.sha256Hex($0) })
        files["manifest.json"] = try DioramaCoding.prettyEncoder.encode(manifest)

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("diorama-bundle-\(UUID().uuidString)")
        let folderName = "diorama-\(safe(s.name))-\(s.id)"
        let folder = work.appendingPathComponent(folderName)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        for (name, data) in files { try data.write(to: folder.appendingPathComponent(name)) }
        try? fm.removeItem(at: zip)
        let (src, dst) = (folder.path, zip.path)
        let status = try await offloadBlocking { () throws -> Int32 in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-c", "-k", "--keepParent", src, dst]
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        }
        guard status == 0 else { throw ClientError("could not create \(zip.path) (ditto exited with \(status))") }
        return manifest
    }

    public static func defaultFileName(_ s: SessionInfo) -> String { "diorama-\(safe(s.name))-\(s.id).zip" }

    static func safe(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }.prefix(60))
    }
}
