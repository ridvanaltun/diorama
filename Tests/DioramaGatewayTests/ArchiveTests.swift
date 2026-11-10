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

@Suite struct ProfileArchiveTests {
    @Test func archivedProfilesLeaveTheListAndComeBack() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        let rule = Rule(id: "r", name: "Rename", match: RuleMatch(tools: ["WebFetch"]), instructions: "x")
        let docs = try await env.client.createProfile(Profile(name: "Docs", rules: [rule]))
        _ = try await env.client.createProfile(Profile(name: "Other", rules: [rule]))
        _ = try await env.client.setFolderDefault("/tmp/diorama-archive-name", profile: "Docs")
        _ = try await env.client.setFolderDefault("/tmp/diorama-archive-id", profile: docs.profileId)
        _ = try await env.client.saveLaunchers([Launcher(name: "Start docs", folder: "/tmp", profile: "Docs")])
        _ = try await env.client.createExperiment(ExperimentDefinition(
            name: "uses docs", task: "t", projectPath: FileManager.default.temporaryDirectory.path,
            variants: [ExperimentVariant(key: "control", name: "c"), ExperimentVariant(key: "s", name: "s", profile: "Docs")], trialsPerVariant: 1))

        let refs = try await env.client.profileReferences("Docs")
        #expect(Set(refs.map { "\($0.kind.rawValue) \($0.label) \($0.byName)" }) == [
            "folderDefault /tmp/diorama-archive-name true", "folderDefault /tmp/diorama-archive-id false",
            "launcher Start docs true", "experiment uses docs true",
        ])
        #expect(try await env.client.profileReferences("Other").isEmpty)

        try await env.client.archiveProfile("Docs")
        #expect(try await env.client.profiles().map(\.name) == ["Other"])
        let archived = try await env.client.profiles(archived: "only")
        #expect(archived.map(\.id) == [docs.profileId] && archived[0].isArchived)
        #expect(try await env.client.profiles(archived: "all").count == 2)
        // By name it's gone; by id its versions stay readable.
        await #expect(throws: ClientError.self) { _ = try await env.client.profile("Docs") }
        #expect(try await env.client.profile(docs.profileId).summary.isArchived)
        #expect(try await env.client.profileReferences(docs.profileId).count == 4)

        // Unarchive by name.
        let back = try await env.client.unarchiveProfile("Docs")
        #expect(back.summary.name == "Docs" && !back.summary.isArchived)
        #expect(try await env.client.profiles().map(\.name) == ["Docs", "Other"])
    }

    @Test func unarchivingRefusesATakenName() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        let rule = Rule(id: "r", name: "Rename", match: RuleMatch(tools: ["WebFetch"]), instructions: "x")
        let old = try await env.client.createProfile(Profile(name: "Docs", rules: [rule]))
        try await env.client.archiveProfile(old.profileId)
        // A new profile takes the name; the archived one is renamed out of the way.
        let new = try await env.client.createProfile(Profile(name: "Docs", rules: [rule]))
        #expect(try await env.client.profiles(archived: "only").first?.name.hasPrefix("Docs (archived ") == true)
        await #expect(throws: ClientError.self) { _ = try await env.client.unarchiveProfile(old.profileId) }

        // Once the name is free again, it comes back under its own name.
        try await env.client.archiveProfile(new.profileId)
        #expect(try await env.client.unarchiveProfile(old.profileId).summary.name == "Docs")
        #expect(try await env.client.profiles(archived: "only").map(\.id) == [new.profileId])
    }
}

@Suite struct ExperimentArchiveTests {
    @Test func archivedExperimentsLeaveTheListButKeepTheirRuns() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        let store = env.daemon.store
        let exp = try await env.client.createExperiment(ExperimentDefinition(
            name: "done", task: "t", projectPath: FileManager.default.temporaryDirectory.path,
            variants: [ExperimentVariant(key: "control", name: "c"), ExperimentVariant(key: "s", name: "s", prompt: SessionPrompt(text: "p"))], trialsPerVariant: 1))
        let other = try await env.client.createExperiment(ExperimentDefinition(
            name: "other", task: "t", projectPath: FileManager.default.temporaryDirectory.path,
            variants: [ExperimentVariant(key: "control", name: "c"), ExperimentVariant(key: "s", name: "s", prompt: SessionPrompt(text: "p"))], trialsPerVariant: 1))
        let est = CostEstimate(trials: 2, perTrialLowUSD: 0, perTrialHighUSD: 0, rewriteLowUSD: 0, rewriteHighUSD: 0, basis: "test", notes: [], confirmationToken: "t")
        let run = try store.createRun(experimentId: exp.id, seed: 1, estimate: est, trials: [("control", 0, 0), ("s", 0, 1)])

        // A run in progress blocks archiving.
        try store.setRunStatus(id: run.id, .running)
        await #expect(throws: ClientError.self) { _ = try await env.client.setExperimentArchived(exp.id, true) }
        try store.setRunStatus(id: run.id, .completed)

        #expect(try await env.client.setExperimentArchived(exp.id, true).isArchived)
        #expect(try await env.client.experiments().map(\.id) == [other.id])
        let archived = try await env.client.experiments(archived: "only")
        #expect(archived.map(\.id) == [exp.id] && archived[0].runs.map(\.id) == [run.id])
        #expect(try await env.client.experiments(archived: "all").count == 2)
        // Nothing is deleted: it and its runs are still reachable by id.
        #expect(try await env.client.experiment(exp.id).isArchived)
        #expect(try await env.client.run(run.id).status == .completed)

        #expect(try await env.client.setExperimentArchived(exp.id, false).isArchived == false)
        #expect(try await env.client.experiments().count == 2)
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
