import DioramaClient
import DioramaCore
import Foundation
import Testing

@Suite struct AuditBundleTests {
    @Test func writesAZipWithAManifestOfHashes() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        _ = try await env.client.createProfile(Profile(name: "web", rules: [Rule(name: "Rename", match: RuleMatch(tools: ["WebFetch"]), instructions: "rename")]))
        let s = try await env.client.createSession(SessionSpec(name: "bundle me", cwd: "/tmp", profile: "web"))
        _ = try await env.post(s.token, body: sampleBody(results: [("toolu_b1", "Example Domain page")]))

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("diorama-bundle-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let zip = dir.appendingPathComponent("b.zip")
        let m = try await AuditBundle.write(client: env.client, sessionId: s.session.id, to: zip)
        #expect(Set(m.files.keys) == ["report.html", "report.md", "decisions.jsonl", "session.json", "timeline.json", "profile.json"])

        let out = dir.appendingPathComponent("x")
        let (zipPath, outPath) = (zip.path, out.path)
        try await offloadBlocking { () throws -> Void in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-x", "-k", zipPath, outPath]
            try p.run()
            p.waitUntilExit()
        }
        let folder = out.appendingPathComponent("diorama-bundle-me-\(s.session.id)")
        for (name, hash) in m.files {
            #expect(Hashing.sha256Hex(try Data(contentsOf: folder.appendingPathComponent(name))) == hash, "\(name) matches the manifest")
        }
        let decisions = try String(contentsOf: folder.appendingPathComponent("decisions.jsonl"), encoding: .utf8)
        #expect(decisions.contains("Morph Test Domain page"), "texts are included")
        let profile = try DioramaCoding.decoder.decode(ProfileVersionInfo.self, from: Data(contentsOf: folder.appendingPathComponent("profile.json")))
        #expect(profile.id == s.session.profileVersionId)
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            let text = String(decoding: try Data(contentsOf: folder.appendingPathComponent(name)), as: UTF8.self)
            #expect(!text.contains("sk-ant-test-key"), "the rewrite key never appears in \(name)")
        }
    }
}
