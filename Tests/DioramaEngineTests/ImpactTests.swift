import DioramaCore
import Foundation
import Testing
@testable import DioramaCore

@Suite struct ImpactTests {
    let t0 = Date(timeIntervalSince1970: 100)

    func rewrite(_ original: String, _ replacement: String, url: String = "https://example.com") -> ImpactAnalysis.Rewrite {
        ImpactAnalysis.Rewrite(toolUseId: "toolu_1", exchangeId: 5, decidedAt: t0, toolName: "WebFetch", toolInput: #"{"url":"\#(url)"}"#,
                               original: original, replacement: replacement)
    }

    func reply(_ text: String, exchange: Int64 = 5, calls: [(String, String)] = []) -> ImpactAnalysis.Output {
        ImpactAnalysis.Output(exchangeId: exchange, at: t0, text: text, toolCalls: calls.map { (name: $0.0, input: $0.1) })
    }

    @Test func findsChangedPhrasesWithContextForShortEdits() {
        let (added, removed) = ImpactAnalysis.changedText(original: "Example Domain heading", replacement: "Morph Test Domain heading")
        #expect(added == ["Morph Test"] && removed == ["Example Domain"], "short changes take a neighboring word")
        let short = ImpactAnalysis.changedText(original: "The latest version 2.3 is stable.", replacement: "The latest version 2.4 is stable.")
        #expect(short.added == ["version 2.4 is"] && short.removed == ["version 2.3 is"], "\(short) \(TextDiff.diff("The latest version 2.3 is stable.", "The latest version 2.4 is stable."))")
    }

    @Test func usedQuestionedCheckedAndSurfaced() {
        let r = rewrite("Example Domain", "Morph Test Domain")
        #expect(ImpactAnalysis.analyze(r, outputs: [reply("The heading is Morph Test Domain.")], repliesVisible: true).signals == [.used])
        let q = ImpactAnalysis.analyze(r, outputs: [reply("This page looks altered; I can't verify it.")], repliesVisible: true)
        #expect(q.signals == [.questioned] && q.label == "questioned")
        let c = ImpactAnalysis.analyze(r, outputs: [reply("", calls: [("WebFetch", #"{"url":"https://example.com","prompt":"again"}"#)])], repliesVisible: true)
        #expect(c.signals == [.checked] && c.evidence == ["Claude fetched https://example.com again"], "\(c)")
        let s = ImpactAnalysis.analyze(r, outputs: [reply("Other sources call it Example Domain.")], repliesVisible: true)
        #expect(s.signals == [.originalSurfaced])
    }

    @Test func statusWithoutSignals() {
        let r = rewrite("Example Domain", "Morph Test Domain")
        #expect(ImpactAnalysis.analyze(r, outputs: [reply("Done.")], repliesVisible: true).status == .noSign)
        #expect(ImpactAnalysis.analyze(r, outputs: [reply("Morph Test", exchange: 4)], repliesVisible: true).status == .pending, "earlier replies don't count")
        let hook = ImpactAnalysis.analyze(r, outputs: [ImpactAnalysis.Output(exchangeId: nil, at: t0.addingTimeInterval(5), text: "", toolCalls: [(name: "Bash", input: "ls")])], repliesVisible: false)
        #expect(hook.status == .notVisible && hook.label == "not visible")
    }
}
