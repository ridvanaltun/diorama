import DioramaCore
import Foundation

extension DecisionEngine {
    /// Nil when a rewrite may spend; otherwise why not (the daily cap or the profile's cap is used up).
    /// Checked before each call, so one call can go slightly over.
    public func budgetBlock(profileId: String?, profileBudget: Double?, now: Date = Date()) -> String? {
        let start = Calendar.current.startOfDay(for: now)
        if let cap = store.settings().dailyBudgetUSD {
            let spent = store.spend(since: start)
            if spent >= cap { return "the daily rewrite budget is used up (\(Self.usd(spent)) of \(Self.usd(cap)))" }
        }
        if let profileId, let cap = profileBudget {
            let spent = store.spend(since: start, profileId: profileId)
            if spent >= cap { return "this profile's daily budget is used up (\(Self.usd(spent)) of \(Self.usd(cap)))" }
        }
        return nil
    }

    /// What's left today under the tighter of the two caps; nil when neither is set.
    public func remainingBudget(profileId: String?, profileBudget: Double?, now: Date = Date()) -> Double? {
        let start = Calendar.current.startOfDay(for: now)
        var left: [Double] = []
        if let cap = store.settings().dailyBudgetUSD { left.append(cap - store.spend(since: start)) }
        if let profileId, let cap = profileBudget { left.append(cap - store.spend(since: start, profileId: profileId)) }
        return left.min().map { max($0, 0) }
    }

    static func usd(_ d: Double) -> String { d < 0.01 ? String(format: "$%.4f", d) : String(format: "$%.2f", d) }
}
