import DioramaCore
import Foundation
import Testing

@Suite struct ProfileDiffTests {
    let a = Rule(id: "a", name: "Rename", match: RuleMatch(tools: ["WebFetch"]), instructions: "Rename the domain.")
    let b = Rule(id: "b", name: "Redact", match: RuleMatch(tools: ["*"]), instructions: "", redact: RedactSpec())
    let c = Rule(id: "c", name: "Search", match: RuleMatch(tools: ["WebSearch"]), instructions: "Steer the query.")

    @Test func identicalProfilesHaveNoChanges() {
        let p = Profile(name: "p", rules: [a, b])
        #expect(ProfileComparison.compare(p, p).isEmpty)
        #expect(ProfileComparison.compare(p, p).text(from: "v1", to: "v2") == "No differences between v1 and v2.")
    }

    @Test func findsAddedRemovedChangedAndMovedRules() {
        var edited = a
        edited.instructions = "Rename the domain heading."
        edited.match.tools = ["WebFetch", "Read"]
        edited.match.input = ["url": "example"]
        var defaults = ProfileDefaults()
        defaults.model = "claude-opus-5-5"
        defaults.review = true
        let old = Profile(name: "p", rules: [a, b, c])
        let new = Profile(name: "p2", rules: [b, edited, Rule(id: "d", name: "New", match: RuleMatch(tools: ["Bash"]), instructions: "x")], defaults: defaults)
        let cmp = ProfileComparison.compare(old, new)

        #expect(cmp.fields.map(\.path) == ["name", "defaults.model", "defaults.review"])
        #expect(cmp.fields[0].old == "p" && cmp.fields[0].new == "p2")
        #expect(cmp.rules.map(\.kind) == [.moved, .changed, .added, .removed])
        #expect(cmp.rules.map(\.name) == ["Redact", "Rename", "New", "Search"])
        let changed = cmp.rules[1]
        #expect(changed.moved)
        #expect(changed.fields.map(\.path) == ["instructions", "match.input.url", "match.tools"])
        #expect(changed.fields[1].old == nil && changed.fields[1].new == "example")
        #expect(changed.fields[2].old == "WebFetch" && changed.fields[2].new == "WebFetch, Read")
        let text = cmp.text(from: "v1", to: "v2")
        #expect(text.contains("~ Changed rule “Rename” (also moved)\n  instructions: Rename the domain. → Rename the domain heading."))
        #expect(text.contains("+ Added rule “New”") && text.contains("- Removed rule “Search”") && text.contains("↕ Moved rule “Redact”"))
    }

    @Test func picksVersionsByNumber() throws {
        func v(_ n: Int) -> ProfileVersionInfo { ProfileVersionInfo(id: "pv_\(n)", profileId: "prof", number: n, createdAt: Date(), profile: Profile(name: "v\(n)")) }
        let detail = ProfileDetail(summary: ProfileSummary(id: "prof", name: "p", currentVersionId: "pv_3", currentVersionNumber: 3, ruleCount: 0, updatedAt: Date()),
                                   current: v(3), versions: [v(3), v(2), v(1)])
        let (x, y) = try ProfileComparison.versions(detail, from: nil, to: nil)
        #expect(x.number == 2 && y.number == 3)
        #expect(try ProfileComparison.versions(detail, from: 1, to: 2).0.number == 1)
        #expect(throws: (any Error).self) { try ProfileComparison.versions(detail, from: nil, to: 1) }
        #expect(throws: (any Error).self) { try ProfileComparison.versions(detail, from: 9, to: nil) }
    }
}
