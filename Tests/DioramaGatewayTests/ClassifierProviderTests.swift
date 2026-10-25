import DioramaCore
import DioramaEngine
import DioramaJSON
import DioramaTestSupport
import Foundation
import Testing

@Suite struct ClassifierProviderTests {
    @Test func anthropicClassifyRequestAndResponse() async throws {
        let mock = MockUpstream { _ in
            .json(#"{"id":"m","type":"message","role":"assistant","model":"claude-haiku-5-5","stop_reason":"end_turn","usage":{"input_tokens":120,"output_tokens":9},"content":[{"type":"text","text":"{\"answer\":\"yes\",\"reason\":\"It lists a price.\"}"}]}"#)
        }
        try await mock.start()
        defer { Task { await mock.stop() } }
        let p = AnthropicRewriteProvider(baseURL: mock.url, apiKey: { "sk-ant-test-key-not-real-000000" })
        let v = await p.classify(ClassifyRequest(toolName: "WebFetch", toolInput: "{}", content: "Price: $10", question: "Does it state a price?", model: "claude-haiku-5-5", timeout: 10))
        #expect(v.answer == true && v.reason == "It lists a price." && v.usage?.inputTokens == 120)
        let req = try #require(mock.requests.first)
        let body = try JSONValue.parse(req.body)
        #expect(body["model"]?.stringValue == "claude-haiku-5-5")
        #expect(body["output_config"]?["format"]?["schema"]?["properties"]?["answer"] != nil)
        #expect(body["messages"]?.canonicalString.contains("Does it state a price?") == true)
        #expect(req.header("x-api-key") == "sk-ant-test-key-not-real-000000")
    }
}
