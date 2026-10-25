import DioramaCore
import Foundation
import Testing
@testable import DioramaApp

@Suite struct NotificationPolicyTests {
    func ev(_ id: Int64, _ kind: SessionEvent.Kind, _ message: String, session: String? = nil, ref: String? = nil) -> SessionEvent {
        SessionEvent(id: id, sessionId: session, kind: kind, message: message, refId: ref, createdAt: Date())
    }

    @Test func runsNotifyAndOpenTheRun() {
        var p = NotificationPolicy()
        let n = p.note(for: ev(1, .runFinished, "Run completed for 'Docs pilot'", ref: "run_1"), sessionName: nil, prefs: .init())
        #expect(n?.title == "Experiment run finished")
        #expect(n?.body == "'Docs pilot' — results are ready.")
        #expect(n?.target == .run("run_1"))
        #expect(p.note(for: ev(2, .runFinished, "Run cancelled for 'Docs pilot'", ref: "run_2"), sessionName: nil, prefs: .init())?.title == "Experiment run cancelled")
        #expect(p.note(for: ev(3, .runFinished, "x", ref: "run_3"), sessionName: nil, prefs: .init(runs: false)) == nil)
        #expect(p.note(for: ev(4, .runStarted, "Run started", ref: "run_3"), sessionName: nil, prefs: .init()) == nil)
    }

    @Test func budgetOncePerDay() {
        var p = NotificationPolicy()
        let now = Date()
        let msg = "Rewrites paused: the daily rewrite budget is used up ($2.00 of $2.00)."
        #expect(p.note(for: ev(1, .warning, msg, session: "s1"), sessionName: nil, prefs: .init(), now: now)?.target == .session("s1"))
        #expect(p.note(for: ev(2, .warning, msg, session: "s2"), sessionName: nil, prefs: .init(), now: now.addingTimeInterval(60)) == nil)
        #expect(p.note(for: ev(3, .warning, msg, session: "s2"), sessionName: nil, prefs: .init(), now: now.addingTimeInterval(86_400)) != nil)
        #expect(p.note(for: ev(4, .warning, "LLM judge skipped", session: nil), sessionName: nil, prefs: .init(), now: now) == nil, "other warnings stay quiet")
    }

    @Test func failuresThrottledPerSession() {
        var p = NotificationPolicy()
        let now = Date()
        let first = p.note(for: ev(1, .rewriteFailed, "WebFetch result failed: HTTP 401", session: "s1"), sessionName: "docs", prefs: .init(), now: now)
        #expect(first?.title == "Rewrites failing in “docs”")
        #expect(first?.body == "WebFetch result failed: HTTP 401. The original results were forwarded.")
        #expect(p.note(for: ev(2, .rewriteFailed, "again", session: "s1"), sessionName: "docs", prefs: .init(), now: now.addingTimeInterval(120)) == nil)
        #expect(p.note(for: ev(3, .rewriteFailed, "other", session: "s2"), sessionName: nil, prefs: .init(), now: now.addingTimeInterval(120)) != nil)
        #expect(p.note(for: ev(4, .rewriteFailed, "later", session: "s1"), sessionName: nil, prefs: .init(), now: now.addingTimeInterval(601)) != nil)
        #expect(p.note(for: ev(5, .rewriteFailed, "off", session: "s3"), sessionName: nil, prefs: .init(failures: false), now: now) == nil)
    }
}
