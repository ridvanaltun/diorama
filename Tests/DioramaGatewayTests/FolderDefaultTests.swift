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

@Suite struct ProfileTestsAPITests {
    @Test func runsSavedAndUnsavedProfiles() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        let rule = Rule(id: "r", name: "Rename", match: RuleMatch(tools: ["WebFetch"]), instructions: "x")
        let test = ProfileTestCase(id: "t", name: "fetch", text: "Example", expectMatch: ["r"])
        _ = try await env.client.createProfile(Profile(name: "web", rules: [rule], tests: [test]))
        #expect(try await env.client.runProfileTests("web").map(\.passed) == [true])
        var draft = Profile(name: "web", rules: [rule], tests: [test])
        draft.rules[0].match.tools = ["Bash"]
        let r = try await env.client.runProfileTests(profile: draft)
        #expect(r.first?.passed == false && r.first?.problems.first?.contains("should match") == true)
        #expect(try await env.client.profile("web").current.profile.tests?.count == 1, "tests are saved with the profile")
        await #expect(throws: ClientError.self) { try await env.client.runProfileTests("missing") }
    }
}
