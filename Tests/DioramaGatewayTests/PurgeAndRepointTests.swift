import DioramaClient
import DioramaCore
import Foundation
import Testing
@testable import DioramaGateway

@Suite struct PurgeTests {
    @Test func purgesOnlyOldArchivedDataAndKeepsSpending() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        let store = env.daemon.store

        // An archived session with a rewrite that cost something, and a live one that stays.
        let old = try await env.client.createSession(SessionSpec(name: "old", cwd: "/tmp", prompt: SessionPrompt(text: "Rename the domain")))
        _ = try await env.post(old.token, body: sampleBody(results: [("toolu_pg1", "Example Domain")]))
        _ = try await env.client.endSession(old.session.id)
        _ = try store.db.run("UPDATE rewrite_attempts SET cost_usd = 0.05 WHERE session_id = ?", [.text(old.session.id)])
        #expect(try await env.client.archiveSessions(ArchiveRequest(sessionIds: [old.session.id])) == 1)
        let kept = try await env.client.createSession(SessionSpec(name: "kept", cwd: "/tmp"))
        _ = try await env.post(kept.token, body: sampleBody(results: [("toolu_pg2", "Example Domain")]))
        _ = try await env.client.endSession(kept.session.id)

        // An archived experiment with a run whose trial has a session.
        let exp = try await env.client.createExperiment(ExperimentDefinition(
            name: "old exp", task: "t", projectPath: FileManager.default.temporaryDirectory.path,
            variants: [ExperimentVariant(key: "control", name: "c"), ExperimentVariant(key: "s", name: "s", prompt: SessionPrompt(text: "p"))], trialsPerVariant: 1))
        let est = CostEstimate(trials: 2, perTrialLowUSD: 0, perTrialHighUSD: 0, rewriteLowUSD: 0, rewriteHighUSD: 0, basis: "test", notes: [], confirmationToken: "t")
        let run = try store.createRun(experimentId: exp.id, seed: 1, estimate: est, trials: [("control", 0, 0), ("s", 0, 1)])
        let trialSession = try await env.client.createSession(SessionSpec(name: "trial", cwd: "/tmp"))
        let trial = try #require(try store.trials(runId: run.id).first)
        _ = try await env.client.endSession(trialSession.session.id)
        _ = try store.db.run("UPDATE trials SET session_id = ?, status = 'succeeded' WHERE id = ?", [.text(trialSession.session.id), .text(trial.id)])
        _ = try store.db.run("UPDATE sessions SET trial_id = ? WHERE id = ?", [.text(trial.id), .text(trialSession.session.id)])
        try store.setRunStatus(id: run.id, .completed)
        _ = try await env.client.setExperimentArchived(exp.id, true)

        let spentBefore = try store.spendHistory(days: 1).days.reduce(0) { $0 + $1.sessionsUSD }
        #expect(spentBefore == 0.05)

        // Everything is younger than a day, so the API finds nothing; the store, two days on, finds it.
        #expect(try await env.client.purgeArchived(PurgeRequest(olderThanDays: 1, dryRun: true)).isEmpty)
        let later = Date().addingTimeInterval(2 * 86_400)
        let plan = try store.purgeArchived(olderThanDays: 1, dryRun: true, now: later)
        #expect(plan.sessions == 1 && plan.experiments == 1 && plan.runs == 1 && plan.trialSessions == 1 && plan.decisions == 1)
        #expect(try await env.client.decision("toolu_pg1").summary.sessionId == old.session.id, "a dry run deletes nothing")

        let done = try store.purgeArchived(olderThanDays: 1, dryRun: false, now: later, blobMinAge: 0)
        #expect(done.sessions == 1 && done.experiments == 1 && !done.dryRun)
        #expect(Set(try await env.client.sessions(archived: "all").map(\.id)) == [kept.session.id])
        await #expect(throws: ClientError.self) { _ = try await env.client.decision("toolu_pg1") }
        #expect(try await env.client.decision("toolu_pg2").summary.sessionId == kept.session.id)
        #expect(try await env.client.experiments(archived: "all").isEmpty)
        #expect(try store.run(id: run.id) == nil)
        #expect(try store.db.query("SELECT COUNT(*) AS n FROM search_docs WHERE session_id = ?", [.text(old.session.id)]).first?.int("n") == 0)
        // Spending history and today's budget keep the purged cost.
        #expect(try store.spendHistory(days: 1).days.reduce(0) { $0 + $1.sessionsUSD } == spentBefore)
        #expect(store.spend(since: Calendar.current.startOfDay(for: Date())) >= 0.05)

        let usage = try await env.client.storageUsage()
        #expect(usage.sessions == 1 && usage.archivedSessions == 0 && usage.experiments == 0)
    }
}

@Suite struct RepointTests {
    @Test func movesNameAndIdReferencesButNotPinnedOnes() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        let rule = Rule(id: "r", name: "Rename", match: RuleMatch(tools: ["WebFetch"]), instructions: "x")
        let docs = try await env.client.createProfile(Profile(name: "Docs", rules: [rule]))
        let other = try await env.client.createProfile(Profile(name: "Other", rules: [rule]))
        _ = try await env.client.setFolderDefault("/tmp/rp-name", profile: "Docs")
        _ = try await env.client.setFolderDefault("/tmp/rp-id", profile: docs.profileId)
        _ = try await env.client.setFolderDefault("/tmp/rp-pinned", profile: docs.id)
        _ = try await env.client.saveLaunchers([Launcher(name: "L", folder: "/tmp", profile: "Docs")])
        let project = env.home.appendingPathComponent("rp-project")
        let settingsFile = try HookInstaller.install(cli: "/x/diorama", config: HookConfig(profile: "Docs"), settings: HookInstaller.projectSettings(project.path),
                                                     registry: env.daemon.hookRegistry)
        let hookId = try #require(HookInstaller.installedCommand(settings: settingsFile).flatMap(HookInstaller.configId(in:)))

        let refs = try await env.client.profileReferences("Docs")
        #expect(refs.first { $0.label == "/tmp/rp-pinned" }?.pinned == true)
        #expect(refs.contains { $0.kind == .hook && $0.byName })

        await #expect(throws: ClientError.self) { _ = try await env.client.repointProfile("Docs", to: "Docs") }
        let moved = try await env.client.repointProfile("Docs", to: "Other")
        #expect(Set(moved.map { "\($0.kind.rawValue) \($0.byName)" }) == ["folderDefault true", "folderDefault false", "launcher true", "hook true"])

        let folders = Dictionary(try await env.client.folderDefaults().map { ($0.path, $0.profile) }, uniquingKeysWith: { a, _ in a })
        #expect(folders["/tmp/rp-name"] == "Other")
        #expect(folders["/tmp/rp-id"] == other.profileId, "an id stays an id")
        #expect(folders["/tmp/rp-pinned"] == docs.id, "pinned versions stay")
        #expect(try await env.client.launchers().first?.profile == "Other")
        #expect(env.daemon.hookRegistry.configs.get(hookId)?.profile == "Other")
        #expect(try await env.client.profileReferences("Docs").map(\.label) == ["/tmp/rp-pinned"])
    }
}
