import DioramaClient
import DioramaCore
import Foundation
import Testing

@Suite struct FolderDefaultTests {
    @Test func nearestFolderWins() {
        var s = DioramaSettings()
        s.folderProfiles = ["/code/app": "web", "/code/app/docs": "docs", "/": "ignored-root"]
        // (These folders don't exist, so no symlinks are resolved.)
        #expect(s.folderDefault(for: "/code/app/src/x")?.profile == "web")
        #expect(s.folderDefault(for: "/code/app/docs/")?.profile == "docs")
        #expect(s.folderDefault(for: "/code/app/docs/../lib")?.path == "/code/app")
        #expect(s.folderDefault(for: "/code/other")?.profile == "ignored-root")
        s.folderProfiles["/"] = nil
        #expect(s.folderDefault(for: "/code/other") == nil)
        #expect(FolderDefault.normalize("~/diorama-no-such-dir/") == FileManager.default.homeDirectoryForCurrentUser.path + "/diorama-no-such-dir")
        #expect(FolderDefault.normalize("/var") == "/private/var", "symlinks resolve when the folder exists")
    }

    @Test func setUnsetAndKeepAcrossSettingsSaves() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        _ = try await env.client.createProfile(Profile(name: "web", rules: [Rule(name: "r", match: RuleMatch(tools: ["*"]), instructions: "x")]))
        let set = try await env.client.setFolderDefault("/tmp/proj/", profile: "web")
        #expect(set.path == "/tmp/proj" && set.profile == "web")
        #expect(try await env.client.folderDefault(for: "/tmp/proj/sub")?.profile == "web")
        #expect(try await env.client.folderDefault(for: "/elsewhere") == nil)

        // Saving settings from an older draft doesn't drop folder defaults.
        var draft = try await env.client.settings()
        draft.folderProfiles = [:]
        draft.retentionDays = 7
        #expect(try await env.client.saveSettings(draft).folderProfiles == ["/tmp/proj": "web"])

        await #expect(throws: ClientError.self) { try await env.client.setFolderDefault("/tmp/x", profile: "missing") }
        await #expect(throws: ClientError.self) { try await env.client.setFolderDefault("relative/path", profile: "web") }
        _ = try await env.client.setFolderDefault("/tmp/proj", profile: nil)
        #expect(try await env.client.folderDefaults().isEmpty)
    }
}
