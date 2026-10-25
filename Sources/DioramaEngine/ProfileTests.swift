import DioramaCore
import DioramaJSON
import Foundation

/// Runs a profile's rule tests: matching only, no model calls (classifier questions aren't asked,
/// so a classifier rule "matches" when its other conditions do). Sampled rules sample by the
/// test's id, so a test's result is stable.
public enum ProfileTests {
    public static func run(_ profile: Profile) -> [ProfileTestResult] {
        (profile.tests ?? []).map { run($0, rules: profile.rules) }
    }

    public static func run(_ t: ProfileTestCase, rules: [Rule]) -> ProfileTestResult {
        let input = t.toolInput.flatMap { try? JSONValue.parse($0) } ?? .object([:])
        let ctx = MatchContext(toolName: t.toolName, toolInput: input, text: t.text, requestClass: "main", isError: t.isError, stage: t.stage, sampleId: t.id)
        let expected = Set(t.expectMatch)
        var problems: [String] = []
        var matched: [String] = []
        for r in rules {
            let why = RuleMatcher.mismatch(r, ctx)
            if why == nil { matched.append(r.name) }
            switch (expected.contains(r.id), why) {
            case (true, let reason?): problems.append("“\(r.name)” should match but doesn't: \(reason)")
            case (false, nil): problems.append("“\(r.name)” matches but shouldn't")
            default: break
            }
        }
        for id in expected where !rules.contains(where: { $0.id == id }) {
            problems.append("expects rule \(id), which isn't in the profile")
        }
        return ProfileTestResult(caseId: t.id, name: t.name, passed: problems.isEmpty, problems: problems, matched: matched)
    }
}
