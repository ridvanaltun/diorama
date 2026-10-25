import DioramaCore
import Foundation
import Testing
@testable import DioramaApp

@Suite struct FormLogicTests {
    @Test func sessionCommandQuotesEverythingAndOmitsEmptyOptions() {
        let plain = FormLogic.sessionCommand(FormLogic.SessionForm(folder: "/tmp/my project"), cli: "/Applications/Diorama.app/Contents/Helpers/diorama")
        #expect(plain == "cd '/tmp/my project' && '/Applications/Diorama.app/Contents/Helpers/diorama' run")

        var f = FormLogic.SessionForm(folder: "/p")
        f.name = "it's a test"
        f.profile = "Docs steer"
        f.prompt = "Say 'v1' is deprecated"
        f.taskContext = true
        f.lockdown = .network
        f.claudeArgs = "--model sonnet"
        let cmd = FormLogic.sessionCommand(f, cli: "diorama")
        #expect(cmd.contains("--name 'it'\\''s a test'"))
        #expect(cmd.contains("--profile 'Docs steer'"))
        #expect(cmd.contains("--prompt 'Say '\\''v1'\\'' is deprecated' --prompt-tools 'WebFetch,WebSearch'"))
        #expect(cmd.contains("--prompt-context task"))
        #expect(cmd.contains("--lockdown network"))
        #expect(cmd.hasSuffix("-- --model sonnet"))
    }

    @Test func pageStageReplacesToolList() {
        var f = FormLogic.SessionForm(folder: "/p")
        f.prompt = "x"
        f.pageStage = true
        let cmd = FormLogic.sessionCommand(f, cli: "diorama")
        #expect(cmd.contains("--prompt-stage page"))
        #expect(!cmd.contains("--prompt-tools"))
        // Whitespace-only prompts and arguments are ignored.
        f.prompt = "   "
        f.claudeArgs = "  "
        #expect(FormLogic.sessionCommand(f, cli: "diorama") == "cd '/p' && 'diorama' run")
    }

    @Test func inputPatternsRoundTripAndKeepEqualsInRegex() {
        let d = FormLogic.parseInputPatterns("url=docs\\.example\\.com\nquery=a=b\n=ignored\nnoequals\n prompt =x")
        #expect(d == ["url": "docs\\.example\\.com", "query": "a=b", "prompt": "x"])
        #expect(FormLogic.parseInputPatterns(FormLogic.formatInputPatterns(d)) == d)
        #expect(FormLogic.parseList(" WebFetch, mcp__*,, Bash ") == ["WebFetch", "mcp__*", "Bash"])
    }

    @Test func experimentDefinitionFromForm() throws {
        var f = FormLogic.ExperimentForm(project: FileManager.default.temporaryDirectory.path)
        f.task = "Do it"
        f.claudeModel = ""
        f.useJudge = true
        f.frozen = false
        f.variants[1].prompt = SessionPrompt(text: "steer it")
        let d = FormLogic.experimentDefinition(f)
        #expect(d.claude.model == nil)
        #expect(d.claude.allowedTools == ["WebFetch", "WebSearch", "Read"])
        #expect(d.treatment == .fresh)
        #expect(d.judge?.enabled == true)
        #expect(d.variants.map(\.name) == ["control", "steered"])
        #expect(d.validate().isEmpty)
        // An empty variant prompt becomes "no prompt" rather than an invalid empty rule.
        f.variants[1].prompt = SessionPrompt(text: "  ")
        #expect(FormLogic.experimentDefinition(f).variants[1].prompt == nil)
    }
}
