import DioramaCore
import Foundation
import Testing
@testable import DioramaGateway

@Suite struct TranscriptTests {
    @Test func readsRepliesButNotThinkingAndJoinsBlocksOfOneResponse() throws {
        let lines = [
            #"{"type":"user","message":{"role":"user","content":"Fetch example.com"},"timestamp":"2026-10-27T10:00:00.000Z"}"#,
            #"{"type":"assistant","requestId":"req_1","timestamp":"2026-10-27T10:00:01.000Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"secret plan"}]}}"#,
            #"{"type":"assistant","requestId":"req_1","timestamp":"2026-10-27T10:00:01.500Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"WebFetch","input":{"url":"https://example.com"}}]}}"#,
            #"not json"#,
            #"{"type":"user","timestamp":"2026-10-27T10:00:03.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"Morph Test Domain"}]}}"#,
            #"{"type":"assistant","requestId":"req_2","timestamp":"2026-10-27T10:00:05.000Z","message":{"role":"assistant","content":[{"type":"text","text":"The heading is"}]}}"#,
            #"{"type":"assistant","requestId":"req_2","timestamp":"2026-10-27T10:00:05.200Z","message":{"role":"assistant","content":[{"type":"text","text":"Morph Test Domain."}]}}"#,
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let replies = try #require(Transcript.replies(path: url.path))
        #expect(replies.count == 2)
        #expect(replies[0].toolUses.map(\.name) == ["WebFetch"] && replies[0].text.isEmpty, "thinking is never read")
        #expect(replies[1].text == "The heading is\nMorph Test Domain.")
        let after = ISO8601DateFormatter().date(from: "2026-10-27T10:00:02Z")!
        #expect(Transcript.firstReply(path: url.path, after: after)?.text == "The heading is\nMorph Test Domain.")
        #expect(Transcript.replies(path: "/no/such/file.jsonl") == nil)
    }
}
