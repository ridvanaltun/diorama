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
