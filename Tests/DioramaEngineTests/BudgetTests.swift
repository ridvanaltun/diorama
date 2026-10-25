import DioramaCore
import DioramaStore
import Foundation
import Testing
@testable import DioramaEngine

@Suite struct BudgetTests {
    @Test func dailyCapPausesInteractiveRewritesButNotExperiments() async throws {
        let store = try tempStore()
        let counter = CallCounter()
        let engine = DecisionEngine(store: store) { countingProvider(counter, .replacing("Example Domain", with: "Morph Test Domain")) }
        let profile = try webProfile(store)
        var settings = store.settings()
        settings.dailyBudgetUSD = 0.05
        try store.saveSettings(settings)
        #expect(engine.budgetBlock(profileId: nil, profileBudget: nil) == nil)

        store.recordSpend(kind: "playground", profileId: nil, costUSD: 0.06)
        #expect(engine.budgetBlock(profileId: nil, profileBudget: nil)?.contains("daily rewrite budget is used up") == true)
        #expect(engine.remainingBudget(profileId: nil, profileBudget: nil) == 0)

        let session = try makeSession(store, profile: profile)
        let body = messagesBody(turns: [(id: "toolu_b1", url: "https://example.com", result: "Example Domain")])
        let r = await engine.process(body: body, session: session, exchangeId: 1, requestClass: "main")
        #expect(r.forwardedBody == nil, "over budget, the original passes through")
        let d = try #require(try store.decision(toolUseId: "toolu_b1"))
        #expect(d.outcome == .unchanged)
        #expect(d.reason.hasPrefix("not rewritten: the daily rewrite budget is used up"))
        #expect(try store.session(id: session.id)?.flags.contains("budget-reached") == true)
        #expect(try store.events(sessionId: session.id).contains { $0.kind == .warning && $0.message.hasPrefix("Rewrites paused") })
        #expect(counter.count == 0)

        // Experiment trials run against their own approved estimate.
        let trial = try store.createSession(SessionSpec(name: "trial", cwd: "/tmp", profile: profile.profileId, kind: .trial, trialId: "tri_x"), tokenHash: Hashing.randomToken())
        let t = await engine.process(body: messagesBody(turns: [(id: "toolu_b2", url: "https://example.com", result: "Example Domain")]), session: trial, exchangeId: 2, requestClass: "main")
        #expect(t.forwardedBody != nil)
        #expect(counter.count == 1)
    }

    @Test func profileCapOnlyAffectsThatProfile() async throws {
        let store = try tempStore()
        let engine = DecisionEngine(store: store) { ScriptedRewriteProvider.replacing("x", with: "y") }
        let a = try store.createProfile(Profile(name: "a", defaults: ProfileDefaults(dailyBudgetUSD: 0.01)))
        let b = try store.createProfile(Profile(name: "b", defaults: ProfileDefaults(dailyBudgetUSD: 0.01)))
        store.recordSpend(kind: "whatif", profileId: a.profileId, costUSD: 0.02)
        #expect(engine.budgetBlock(profileId: a.profileId, profileBudget: 0.01)?.contains("this profile's daily budget") == true)
        #expect(engine.budgetBlock(profileId: b.profileId, profileBudget: 0.01) == nil)
        #expect(store.spend(since: Calendar.current.startOfDay(for: Date())) == 0.02)
        #expect(store.spendByProfile(since: Calendar.current.startOfDay(for: Date())) == [a.profileId: 0.02])
        // Yesterday's spending doesn't count today.
        #expect(engine.budgetBlock(profileId: a.profileId, profileBudget: 0.01, now: Date().addingTimeInterval(86_400)) == nil)
    }
}
