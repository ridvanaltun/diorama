import DioramaClient
import DioramaCore
import DioramaStore
import Foundation
import Testing

@Suite struct SpendHistoryTests {
    func attempt(_ store: Store, session: String, cost: Double, at: Date) throws {
        let info = RewriteAttemptInfo(id: Hashing.newId(prefix: "att"), provider: "scripted", modelRequested: "m", modelServed: "m", promptVersion: "v",
                                      status: .succeeded, error: nil, usage: nil, costUSD: cost, latencyMs: 1, explanation: nil, mode: nil, edits: [], createdAt: at)
        try store.insertAttempt(AttemptRecord(info: info, toolUseId: "toolu_\(UUID().uuidString)", sessionId: session, requestBlob: nil, responseBlob: nil))
    }

    @Test func bucketsByLocalDayAndSource() throws {
        let store = try tempStore()
        let profile = try store.createProfile(Profile(name: "web", rules: [Rule(name: "r", match: RuleMatch(tools: ["*"]), instructions: "x")]))
        let s = try store.createSession(SessionSpec(name: "s", cwd: "/tmp", profile: "web"), tokenHash: "h1")
        let t = try store.createSession(SessionSpec(name: "t", cwd: "/tmp", profile: "web", kind: .trial, trialId: "tri_1"), tokenHash: "h2")
        let cal = Calendar.current
        let now = Date()
        let yesterday = cal.date(byAdding: .day, value: -1, to: now)!
        try attempt(store, session: s.id, cost: 0.10, at: now)
        try attempt(store, session: t.id, cost: 0.05, at: now)
        try attempt(store, session: s.id, cost: 0.20, at: yesterday)
        try attempt(store, session: s.id, cost: 9, at: cal.date(byAdding: .day, value: -40, to: now)!)
        store.recordSpend(kind: "playground", profileId: profile.profileId, costUSD: 0.01)

        let h = try store.spendHistory(days: 7, now: now)
        #expect(h.days.count == 7 && h.days.last?.day == cal.startOfDay(for: now))
        let today = try #require(h.days.last)
        #expect(abs(today.sessionsUSD - 0.10) < 1e-9 && abs(today.trialsUSD - 0.05) < 1e-9 && abs(today.previewsUSD - 0.01) < 1e-9)
        #expect(today.calls == 2 && abs((today.byProfile["web"] ?? 0) - 0.16) < 1e-9)
        #expect(abs(h.days[5].sessionsUSD - 0.20) < 1e-9)
        #expect(abs(h.totalUSD - 0.36) < 1e-9, "the 40-day-old attempt is outside the window")

        let text = SpendHistoryText.render(h)
        #expect(text.contains("$0.36 in total") && text.contains("web: $0.36"))
        #expect(SpendHistoryText.render(try tempStore().spendHistory(days: 3)).hasSuffix("(nothing spent)"))
    }
}
