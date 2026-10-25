import DioramaCore
import DioramaEngine
import Foundation
import Testing

@Suite struct ProfileTestsTests {
    let docs = Rule(id: "docs", name: "Docs", match: RuleMatch(tools: ["WebFetch"], input: ["url": "docs\\."]), instructions: "x")
    let prices = Rule(id: "prices", name: "Prices", match: RuleMatch(tools: ["WebFetch"], content: "\\$[0-9]"), instructions: "y")

    @Test func reportsRulesThatMatchWhenTheyShouldntAndViceVersa() {
        let ok = ProfileTestCase(id: "t1", name: "docs page", toolInput: #"{"url":"https://docs.example.com"}"#, text: "Intro", expectMatch: ["docs"])
        let bad = ProfileTestCase(id: "t2", name: "pricing", toolInput: #"{"url":"https://docs.example.com/pricing"}"#, text: "Plans from $9", expectMatch: ["prices"])
        let ghost = ProfileTestCase(id: "t3", name: "ghost", text: "x", expectMatch: ["gone"])
        let results = ProfileTests.run(Profile(name: "p", rules: [docs, prices], tests: [ok, bad, ghost]))
        #expect(results.map(\.passed) == [true, false, false])
        #expect(results[0].matched == ["Docs"])
        #expect(results[1].problems == ["“Docs” matches but shouldn't"])
        #expect(results[2].problems == ["expects rule gone, which isn't in the profile"])
        let missing = ProfileTests.run(ProfileTestCase(name: "m", toolInput: #"{"url":"https://example.com"}"#, text: "x", expectMatch: ["docs"]), rules: [docs])
        #expect(missing.problems.first?.hasPrefix("“Docs” should match but doesn't: input “url”") == true)
    }

    @Test func profilesWithoutTestsKeepTheirJSON() throws {
        let p = Profile(name: "p", rules: [docs], tests: [])
        #expect(p.tests == nil)
        let json = String(decoding: try DioramaCoding.encoder.encode(p), as: UTF8.self)
        #expect(!json.contains("tests"))
        let back = try DioramaCoding.decoder.decode(Profile.self, from: Data(#"{"name":"p","tests":[]}"#.utf8))
        #expect(back.tests == nil)
        let withTests = Profile(name: "p", rules: [docs], tests: [ProfileTestCase(id: "t", name: "t", text: "x", expectMatch: [])])
        #expect(ProfileComparison.compare(p, withTests).fields.map(\.path) == ["tests"])
    }
}
