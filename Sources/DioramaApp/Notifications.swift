import AppKit
import DioramaCore
import Foundation
import UserNotifications

/// Which daemon events become macOS notifications, and how often (pure, unit-tested).
struct NotificationPolicy {
    struct Prefs: Equatable {
        var runs = true
        var budget = true
        var failures = true
        var reviews = true

        static let runsKey = "notifyRuns", budgetKey = "notifyBudget", failuresKey = "notifyFailures", reviewsKey = "notifyReviews"

        static func load(_ d: UserDefaults = .standard) -> Prefs {
            Prefs(runs: d.object(forKey: runsKey) as? Bool ?? true, budget: d.object(forKey: budgetKey) as? Bool ?? true,
                  failures: d.object(forKey: failuresKey) as? Bool ?? true, reviews: d.object(forKey: reviewsKey) as? Bool ?? true)
        }
    }

    enum Target: Equatable {
        case run(String)
        case session(String)
        case reviews
    }

    struct Note: Equatable {
        var id: String
        var title: String
        var body: String
        var target: Target?
    }

    /// Rewrite failures notify at most once per session in this window.
    static let failureWindow: TimeInterval = 600
    private var lastFailure: [String: Date] = [:]
    private var budgetDay: Date?

    mutating func note(for ev: SessionEvent, sessionName: String?, prefs: Prefs, now: Date = Date()) -> Note? {
        switch ev.kind {
        case .runFinished where prefs.runs:
            let cancelled = ev.message.contains("cancelled")
            return Note(id: "run-\(ev.id)", title: cancelled ? "Experiment run cancelled" : "Experiment run finished",
                        body: ev.message.replacingOccurrences(of: "Run completed for ", with: "").replacingOccurrences(of: "Run cancelled for ", with: "")
                            + (cancelled ? "" : " — results are ready."),
                        target: ev.refId.map { .run($0) })
        case .warning where prefs.budget && ev.message.hasPrefix("Rewrites paused"):
            // One per day: the cap is global, so further sessions hitting it add nothing new.
            let day = Calendar.current.startOfDay(for: now)
            guard budgetDay != day else { return nil }
            budgetDay = day
            return Note(id: "budget-\(ev.id)", title: "Rewrite budget used up",
                        body: "Matching tool results pass through unchanged until tomorrow, or until you raise the budget in Settings.",
                        target: ev.sessionId.map { .session($0) })
        case .reviewRequested where prefs.reviews:
            return Note(id: "review-\(ev.id)", title: "Rewrite waiting for review" + (sessionName.map { " in “\($0)”" } ?? ""),
                        body: ev.message.replacingOccurrences(of: " rewrite waiting for review: ", with: ": ") + " Claude waits until you answer.",
                        target: .reviews)
        case .rewriteFailed where prefs.failures:
            guard let sid = ev.sessionId else { return nil }
            if let last = lastFailure[sid], now.timeIntervalSince(last) < Self.failureWindow { return nil }
            lastFailure[sid] = now
            return Note(id: "fail-\(ev.id)", title: "Rewrites failing" + (sessionName.map { " in “\($0)”" } ?? ""),
                        body: ev.message + ". The original results were forwarded.", target: .session(sid))
        default:
            return nil
        }
    }
}

/// Delivers notes through UserNotifications and routes clicks back into the app.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    /// Set by the app: what a clicked notification opens.
    var open: ((NotificationPolicy.Target) -> Void)?
    private var policy = NotificationPolicy()
    private var requested = false

    /// Off in snapshot mode and when the binary isn't inside an app bundle (UserNotifications needs one).
    var isAvailable: Bool {
        ProcessInfo.processInfo.environment["DIORAMA_SNAPSHOT_DIR"] == nil && Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    func start() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    func handle(_ ev: SessionEvent, sessionName: String?) {
        guard isAvailable, let note = policy.note(for: ev, sessionName: sessionName, prefs: .load()) else { return }
        post(note)
    }

    func post(_ note: NotificationPolicy.Note) {
        guard isAvailable else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            if !requested {
                requested = true
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
            let content = UNMutableNotificationContent()
            content.title = note.title
            content.body = note.body
            content.sound = .default
            switch note.target {
            case .run(let id): content.userInfo = ["run": id]
            case .session(let id): content.userInfo = ["session": id]
            case .reviews: content.userInfo = ["reviews": true]
            case nil: break
            }
            try? await center.add(UNNotificationRequest(identifier: note.id, content: content, trigger: nil))
        }
    }

    /// Current permission, for Settings.
    func authorization() async -> UNAuthorizationStatus {
        guard isAvailable else { return .denied }
        return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    // While Diorama is in front the timeline already shows what happened; only notify in the background.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        await MainActor.run { NSApp.isActive } ? [] : [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let target: NotificationPolicy.Target? = (info["run"] as? String).map { .run($0) } ?? (info["session"] as? String).map { .session($0) }
            ?? (info["reviews"] != nil ? .reviews : nil)
        await MainActor.run {
            if let target { self.open?(target) }
        }
    }
}
