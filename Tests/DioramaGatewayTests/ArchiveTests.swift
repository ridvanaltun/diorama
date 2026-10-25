import DioramaClient
import DioramaCore
import Foundation
import Testing

@Suite struct ArchiveTests {
    @Test func archivedSessionsLeaveTheListButStay() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        let running = try await env.client.createSession(SessionSpec(name: "running", cwd: "/tmp"))
        let done = try await env.client.createSession(SessionSpec(name: "done", cwd: "/tmp"))
        _ = try await env.post(done.token, body: sampleBody(results: [("toolu_ar1", "Example Domain")]))
        _ = try await env.client.endSession(done.session.id)

        #expect(try await env.client.archiveSessions(ArchiveRequest(sessionIds: [running.session.id, done.session.id])) == 1, "running sessions are skipped")
        #expect(try await env.client.sessions().map(\.id) == [running.session.id])
        let archived = try await env.client.sessions(archived: "only")
        #expect(archived.map(\.id) == [done.session.id] && archived[0].isArchived)
        #expect(try await env.client.sessions(archived: "all").count == 2)
        // Nothing is deleted: its records, search and exports still work.
        #expect(try await env.client.decision("toolu_ar1").summary.sessionId == done.session.id)
        #expect(try await env.client.exportDecisions(sessionId: done.session.id).rows == 1)

        #expect(try await env.client.archiveSessions(ArchiveRequest(sessionIds: [done.session.id], archived: false)) == 1)
        #expect(try await env.client.sessions().count == 2)

        // Bulk: ended sessions older than N days (none are, yet), then 0 days covers every ended one.
        _ = try await env.client.endSession(running.session.id)
        #expect(try await env.client.archiveSessions(ArchiveRequest(olderThanDays: 30)) == 0)
        #expect(try await env.client.archiveSessions(ArchiveRequest(olderThanDays: 0)) == 2)
        #expect(try await env.client.sessions().isEmpty)
    }
}

@Suite struct DoctorConfigurationTests {
    @Test func flagsConfigurationThatStopsOrSurprisesSteering() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        func names() async throws -> [String: String] {
            Dictionary(try await env.client.doctor().checks.map { ($0.name, $0.detail) }, uniquingKeysWith: { a, b in a + " | " + b })
        }
        #expect(try await names()["Steering"] == nil)

        let rule = Rule(id: "r", name: "Rename", match: RuleMatch(tools: ["WebFetch"]), instructions: "x")
        _ = try await env.client.createProfile(Profile(name: "broken", rules: [rule], tests: [ProfileTestCase(name: "t", toolName: "Bash", text: "x", expectMatch: ["r"])]))
        _ = try await env.client.createProfile(Profile(name: "quiet", rules: [rule], defaults: ProfileDefaults(shadow: true)))
        _ = try await env.client.setFolderDefault("/tmp/diorama-doctor-missing", profile: "quiet")
        try await env.client.archiveProfile("quiet")
        _ = try await env.client.setSteeringPaused(true)

        let checks = try await names()
        #expect(checks["Steering"]?.contains("paused everywhere") == true)
        #expect(checks["Rule tests"]?.contains("“broken” (1 of 1)") == true)
        #expect(checks["Folder default"]?.contains("'quiet', which doesn't exist") == true)
        #expect(checks["Shadow mode"] == nil, "archived profiles don't count")
    }
}
