import DioramaCore
import DioramaJSON
import DioramaStore
import Foundation
import Testing
@testable import DioramaEngine

@Suite struct HookOutputMappingTests {
    func paths(_ tool: String, _ json: String) throws -> [HookOutputMapping.Path] {
        HookOutputMapping.textPaths(toolName: tool, response: try JSONValue.parse(json))
    }

    @Test func knowsTheBuiltInToolShapes() throws {
        // Shapes recorded from Claude Code 2.1.308 (docs/poc-findings.md).
        #expect(try paths("Read", #"{"type":"text","file":{"filePath":"/a","content":"hi","numLines":1}}"#) == [[.key("file"), .key("content")]])
        #expect(try paths("Read", #"{"type":"image","file":{"base64":"AAAA"}}"#).isEmpty)
        #expect(try paths("WebFetch", #"{"bytes":5,"code":200,"result":"Heading","url":"https://e.com"}"#) == [[.key("result")]])
        #expect(try paths("Bash", #"{"stdout":"out","stderr":"","interrupted":false}"#) == [[.key("stdout")]])
        #expect(try paths("Bash", #"{"stdout":"out","stderr":"warn"}"#) == [[.key("stdout")], [.key("stderr")]])
        #expect(try paths("Grep", #"{"mode":"content","content":"a.txt:1:hello"}"#) == [[.key("content")]])
        #expect(try paths("Grep", #"{"mode":"files_with_matches","filenames":["a.txt"]}"#).isEmpty)
        #expect(try paths("WebSearch", #"{"query":"q","results":["Summary text",{"tool_use_id":"x","content":[]}]}"#) == [[.key("results"), .index(0)]])
    }

    @Test func handlesMCPAndUnknownShapes() throws {
        #expect(try paths("mcp__docs__fetch", #"[{"type":"text","text":"a"},{"type":"image","data":"x"},{"type":"text","text":"b"}]"#)
                == [[.index(0), .key("text")], [.index(2), .key("text")]])
        #expect(try paths("mcp__docs__fetch", #"{"content":[{"type":"text","text":"a"}],"isError":false}"#) == [[.key("content"), .index(0), .key("text")]])
        #expect(try paths("Whatever", #""plain text""#) == [[]])
        #expect(try paths("Whatever", #"{"output":"x","other":"y"}"#) == [[.key("output")]])
        #expect(try paths("Whatever", #"{"n":1}"#).isEmpty)
    }

    @Test func setReplacesOnlyTheTargetedString() throws {
        let v = try JSONValue.parse(#"{"type":"text","file":{"content":"old","numLines":3}}"#)
        let out = HookOutputMapping.set(v, [.key("file"), .key("content")], .string("new"))
        #expect(HookOutputMapping.get(out, [.key("file"), .key("content")])?.stringValue == "new")
        #expect(HookOutputMapping.get(out, [.key("file"), .key("numLines")]) == .number("3"))
        #expect(HookOutputMapping.set(v, [.key("missing"), .key("x")], .string("new")) == v)
    }
}

@Suite struct HookDecisionTests {
    func readProfile(_ store: Store) throws -> ProfileVersionInfo {
        try store.createProfile(Profile(name: "read-\(UUID().uuidString.prefix(6))", rules: [
            Rule(id: "r1", name: "Rename", match: RuleMatch(tools: ["Read"]), instructions: "rename the domain"),
        ]))
    }

    func hookSession(_ store: Store, profile: ProfileVersionInfo?) throws -> SessionRecord {
        try store.createSession(SessionSpec(name: "h", cwd: "/tmp", profile: profile?.profileId, via: .hook), tokenHash: "hook:" + Hashing.randomToken())
    }

    let readResponse = #"{"type":"text","file":{"filePath":"/p/notes.txt","content":"Title: Example Domain\n","numLines":2,"startLine":1,"totalLines":2}}"#

    @Test func rewritesTheTextAndKeepsTheOutputShape() async throws {
        let store = try tempStore()
        let counter = CallCounter()
        let engine = DecisionEngine(store: store) { countingProvider(counter, .replacing("Example Domain", with: "Morph Test Domain")) }
        let session = try hookSession(store, profile: try readProfile(store))
        let (d, out) = await engine.decideHook(session: session, toolUseId: "toolu_h1", toolName: "Read", toolInputJSON: #"{"file_path":"/p/notes.txt"}"#, responseJSON: readResponse, taskText: nil)
        #expect(d?.outcome == .rewritten)
        let json = try JSONValue.parse(try #require(out))
        #expect(HookOutputMapping.get(json, [.key("file"), .key("content")])?.stringValue == "Title: Morph Test Domain\n")
        #expect(HookOutputMapping.get(json, [.key("file"), .key("numLines")]) == .number("2"))
        #expect(HookOutputMapping.get(json, [.key("type")])?.stringValue == "text")
        #expect(d?.exchangeId == 0)
        #expect(try store.info(session).via == .hook)

        // A repeated hook call for the same tool_use_id gets the same bytes, without a new rewrite.
        let (again, out2) = await engine.decideHook(session: session, toolUseId: "toolu_h1", toolName: "Read", toolInputJSON: nil, responseJSON: readResponse, taskText: nil)
        #expect(again?.outcome == .rewritten)
        #expect(out2 == out)
        #expect(counter.count == 1)
    }

    @Test func leavesResultsAloneWithoutRulesOrAKnownShape() async throws {
        let store = try tempStore()
        let counter = CallCounter()
        let engine = DecisionEngine(store: store) { countingProvider(counter, .replacing("Example Domain", with: "X")) }
        let none = try hookSession(store, profile: nil)
        let (d1, out1) = await engine.decideHook(session: none, toolUseId: "toolu_h2", toolName: "Read", toolInputJSON: nil, responseJSON: readResponse, taskText: nil)
        #expect(d1?.outcome == .unchanged)
        #expect(d1?.reason == "no rules configured")
        #expect(out1 == nil)

        let all = try store.createProfile(Profile(name: "all", rules: [Rule(name: "all", match: RuleMatch(tools: ["*"]), instructions: "x")]))
        let s = try hookSession(store, profile: all)
        let (d2, out2) = await engine.decideHook(session: s, toolUseId: "toolu_h3", toolName: "Edit", toolInputJSON: nil, responseJSON: #"{"filePath":"/a","structuredPatch":[]}"#, taskText: nil)
        #expect(d2?.outcome == .unchanged)
        #expect(d2?.reason.contains("can't read this Edit output") == true)
        #expect(out2 == nil)

        let (d3, out3) = await engine.decideHook(session: s, toolUseId: "toolu_h4", toolName: "Read", toolInputJSON: nil, responseJSON: "{not json", taskText: nil)
        #expect(d3 == nil && out3 == nil)
        #expect(counter.count == 0)
    }
}
