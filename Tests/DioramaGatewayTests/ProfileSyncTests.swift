import DioramaClient
import DioramaCore
import Foundation
import Testing

@Suite(.serialized) struct ProfileSyncTests {
    func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("diorama-sync-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("nested/node_modules"), withIntermediateDirectories: true)
        return URL(fileURLWithPath: FolderDefault.normalize(dir.path))
    }

    func write(_ url: URL, _ json: String) throws {
        try json.write(to: url, atomically: true, encoding: .utf8)
        // A distinct modification time, so the next pass sees the change.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(Double.random(in: 1...1000))], ofItemAtPath: url.path)
    }

    let profileJSON = #"{"name":"Team docs","rules":[{"id":"r","name":"Rename","match":{"tools":["WebFetch"]},"instructions":"rename"}]}"#

    @Test func filesBecomeProfilesAndChangesBecomeVersions() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write(dir.appendingPathComponent("team.json"), profileJSON)
        try write(dir.appendingPathComponent("package.json"), #"{"name":"not-a-profile","version":"1.0.0"}"#)
        try write(dir.appendingPathComponent("nested/broken.json"), #"{"name":"Broken","rules":[{"name":"x","match":{"tools":[]},"instructions":"y"}]}"#)
        try write(dir.appendingPathComponent("nested/node_modules/skip.json"), #"{"name":"Skip","rules":[]}"#)

        var status = try await env.client.setProfileFolder(dir.path, watched: true)
        let files = try #require(status.first?.files)
        #expect(files.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["broken.json", "team.json"], "package.json and node_modules are skipped")
        #expect(files[1].profileName == "Team docs" && files[1].error == nil)
        #expect(files[0].error?.contains("matches no tools") == true)
        #expect(try await env.client.profiles().map(\.name) == ["Team docs"])
        let detail = try await env.client.profile("Team docs")
        #expect(detail.syncedFile == dir.appendingPathComponent("team.json").path)

        // Changing the file makes a new version; an unchanged file doesn't.
        try write(dir.appendingPathComponent("team.json"), profileJSON.replacingOccurrences(of: "rename", with: "rename the heading"))
        status = try await env.client.syncProfileFolders()
        #expect(try await env.client.profile("Team docs").current.number == 2)
        status = try await env.client.syncProfileFolders()
        #expect(try await env.client.profile("Team docs").current.number == 2)

        // App edits go back with write-file, without another version on the next pass.
        var p = try await env.client.profile("Team docs").current.profile
        p.description = "edited in the app"
        _ = try await env.client.updateProfile("Team docs", p)
        let path = try await env.client.writeProfileToFile("Team docs")
        #expect(try String(contentsOfFile: path, encoding: .utf8).contains("edited in the app"))
        _ = try await env.client.syncProfileFolders()
        #expect(try await env.client.profile("Team docs").current.number == 3)

        // A second file with the same name doesn't take over the profile.
        try write(dir.appendingPathComponent("nested/copy.json"), profileJSON)
        status = try await env.client.syncProfileFolders()
        #expect(status.first?.files.first { $0.path.hasSuffix("copy.json") }?.error?.contains("already synced from") == true)

        // Deleting the file keeps the profile; unwatching keeps it too.
        try FileManager.default.removeItem(at: dir.appendingPathComponent("team.json"))
        status = try await env.client.profileFolders()
        #expect(status.first?.files.first { $0.path.hasSuffix("team.json") }?.missing == true)
        _ = try await env.client.setProfileFolder(dir.path, watched: false)
        #expect(try await env.client.profiles().map(\.name) == ["Team docs"])
        await #expect(throws: ClientError.self) { try await env.client.setProfileFolder("/no/such/folder", watched: true) }
    }
}
