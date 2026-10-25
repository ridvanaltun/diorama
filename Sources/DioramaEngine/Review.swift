import DioramaCore
import DioramaStore
import Foundation

/// Rewrites waiting for the user's verdict. Each waits at most its timeout; anything that
/// doesn't get an answer resolves as `.timedOut` (and the original is forwarded).
public actor ReviewCenter {
    private var waiting: [String: (review: PendingReview, resume: CheckedContinuation<ReviewVerdict, Never>)] = [:]

    public init() {}

    public var pending: [PendingReview] { waiting.values.map(\.review).sorted { $0.createdAt < $1.createdAt } }

    /// `registered` runs once the review can be answered (so an answer to its event is never lost).
    func wait(for review: PendingReview, registered: @Sendable () -> Void) async -> ReviewVerdict {
        let delay = max(review.expiresAt.timeIntervalSinceNow, 0)
        let id = review.id
        return await withCheckedContinuation { c in
            waiting[id] = (review, c)
            registered()
            Task {
                try? await Task.sleep(for: .seconds(delay))
                self.resolve(id, .timedOut)
            }
        }
    }

    /// Returns false if nothing is waiting under `id` (already answered or timed out).
    @discardableResult
    public func resolve(_ id: String, _ verdict: ReviewVerdict) -> Bool {
        guard let w = waiting.removeValue(forKey: id) else { return false }
        w.resume.resume(returning: verdict)
        return true
    }

    /// Resolves everything (daemon shutdown): the originals are forwarded.
    public func expireAll() {
        for id in Array(waiting.keys) { resolve(id, .timedOut) }
    }
}

extension DecisionEngine {
    /// In hook mode, a review must end this long after the tool result arrived (the hook's own timeout is 180 s).
    static let hookReviewDeadline: TimeInterval = 150

    static func clampedReviewTimeout(_ seconds: Double) -> Double {
        min(max(seconds, ProfileDefaults.reviewTimeoutRange.lowerBound), ProfileDefaults.reviewTimeoutRange.upperBound)
    }

    func requestReview(_ t: DecisionTarget, session: SessionRecord, original: [String], proposed: [String], explanation: String,
                       rules: [String], timeout: Double, deadline: Date?) async -> ReviewVerdict {
        let now = Date()
        var expires = now.addingTimeInterval(Self.clampedReviewTimeout(timeout))
        if let deadline { expires = min(expires, deadline) }
        guard expires > now.addingTimeInterval(5) else { return .timedOut }
        let review = PendingReview(
            id: t.decisionId, sessionId: session.id, sessionName: session.name, toolName: t.toolName ?? "tool", toolInput: t.toolInputJSON,
            stage: t.stage, originalText: original.joined(separator: "\n\n"), proposedText: proposed.joined(separator: "\n\n"),
            explanation: explanation, rules: rules, createdAt: now, expiresAt: expires)
        let verdict = await reviews.wait(for: review) { [store] in
            store.addEvent(sessionId: session.id, kind: .reviewRequested, message: "\(review.toolName) rewrite waiting for review: \(explanation)", refId: review.id)
        }
        let text = switch verdict {
        case .approved: "approved"
        case .rejected: "rejected"
        case .timedOut: "not reviewed in time"
        }
        store.addEvent(sessionId: session.id, kind: .reviewResolved, message: "\(review.toolName) rewrite \(text)", refId: review.id)
        return verdict
    }
}
