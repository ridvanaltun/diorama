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

@Suite struct ProfileImportTests {
    @Test func importsExportedProfilesAndSavedVersions() throws {
        let p = Profile(name: "Docs steer", rules: [Rule(name: "Rename", match: RuleMatch(tools: ["WebFetch"]), instructions: "rename")])
        let exported = try DioramaCoding.prettyEncoder.encode(p)
        #expect(try FormLogic.importedProfile(exported, existingNames: []) == p)
        let version = try DioramaCoding.encoder.encode(ProfileVersionInfo(id: "pv_1", profileId: "prof", number: 3, createdAt: Date(), profile: p))
        #expect(try FormLogic.importedProfile(version, existingNames: []).rules == p.rules)
    }

    @Test func renamesOnClashAndRejectsOtherJSON() throws {
        let data = try DioramaCoding.encoder.encode(Profile(name: "Docs steer"))
        #expect(try FormLogic.importedProfile(data, existingNames: ["Docs steer"]).name == "Docs steer (2)")
        #expect(try FormLogic.importedProfile(data, existingNames: ["Docs steer", "Docs steer (2)"]).name == "Docs steer (3)")
        #expect(throws: FormLogic.ImportError.self) { try FormLogic.importedProfile(Data(#"{"hello":1}"#.utf8), existingNames: []) }
        #expect(throws: FormLogic.ImportError.self) { try FormLogic.importedProfile(Data("not json".utf8), existingNames: []) }
        #expect(FormLogic.exportFileName("a/b: c") == "a-b- c.diorama-profile.json")
    }
}

@Suite struct LauncherTests {
    @Test func savesAFormAndBuildsItsCommand() {
        var f = FormLogic.SessionForm(folder: "/tmp/my app")
        f.profile = "Docs steer"
        f.prompt = "Say v1 is deprecated"
        f.promptTools = "WebFetch, WebSearch"
        f.lockdown = .network
        f.claudeArgs = "--model sonnet"
        let l = FormLogic.launcher(f, name: "Docs on app")
        #expect(l.runArguments == ["run", "--name", "Docs on app", "--profile", "Docs steer", "--prompt", "Say v1 is deprecated",
                                   "--prompt-tools", "WebFetch,WebSearch", "--lockdown", "network", "--", "--model", "sonnet"])
        #expect(FormLogic.launchCommand(l, cli: "/A/diorama") ==
                "cd '/tmp/my app' && '/A/diorama' run '--name' 'Docs on app' '--profile' 'Docs steer' '--prompt' 'Say v1 is deprecated' '--prompt-tools' 'WebFetch,WebSearch' '--lockdown' 'network' -- --model sonnet")
        let plain = FormLogic.launcher(FormLogic.SessionForm(folder: "/p"), name: "plain")
        #expect(plain.runArguments == ["run", "--name", "plain"])
    }

    @Test func openCodeSessionsAndLaunchersPassTheAgent() throws {
        var f = FormLogic.SessionForm(folder: "/p")
        f.agent = .opencode
        f.claudeArgs = "run -m anthropic/claude-sonnet-4-5 hi"
        #expect(FormLogic.sessionCommand(f, cli: "diorama") == "cd '/p' && 'diorama' run --agent opencode -- run -m anthropic/claude-sonnet-4-5 hi")
        let l = FormLogic.launcher(f, name: "OC")
        #expect(l.agent == .opencode)
        #expect(l.runArguments == ["run", "--name", "OC", "--agent", "opencode", "--", "run", "-m", "anthropic/claude-sonnet-4-5", "hi"])
        // Claude Code launchers don't store an agent, so earlier versions read them unchanged.
        #expect(FormLogic.launcher(FormLogic.SessionForm(folder: "/p"), name: "C").agent == nil)
        let old = try JSONDecoder().decode(Launcher.self, from: Data(#"{"id":"a","name":"A","folder":"/a","promptTools":[],"taskContext":false,"pageStage":false,"lockdown":"none","claudeArgs":""}"#.utf8))
        #expect(old.agent == nil && !old.runArguments.contains("--agent"))
    }

    @Test func openCodeExperimentFormSetsTheAgentAndDropsTheBudget() {
        var f = FormLogic.ExperimentForm(project: "/p")
        f.claudeModel = "claude-sonnet-4-5"
        #expect(FormLogic.experimentDefinition(f).agent == nil && FormLogic.experimentDefinition(f).claude.maxBudgetUSD == 2)
        f.agent = .opencode
        let d = FormLogic.experimentDefinition(f)
        #expect(d.runsOpenCode && d.claude.maxBudgetUSD == nil && d.claude.model == "claude-sonnet-4-5")
    }

    @Test func archiveMessageListsWhatStopsFindingTheProfile() {
        let plain = FormLogic.archiveProfileMessage([ProfileReference(kind: .folderDefault, label: "/by/id", byName: false)])
        #expect(plain.contains("unarchive it later") && !plain.contains("won't find it"))
        let m = FormLogic.archiveProfileMessage([
            ProfileReference(kind: .launcher, label: "Start", byName: true),
            ProfileReference(kind: .experiment, label: "Exp", byName: true),
            ProfileReference(kind: .folderDefault, label: "/by/id", byName: false),
            ProfileReference(kind: .syncedFile, label: "/repo/profiles/docs.json", byName: false),
        ])
        #expect(m.contains("• Launcher “Start”") && m.contains("• Experiment “Exp” (new runs)"))
        #expect(!m.contains("/by/id"))
        #expect(m.contains("synced from /repo/profiles/docs.json"))
    }

    @Test func duplicateKeepsSettingsTheFormDoesNotShow() {
        var original = ExperimentDefinition(
            name: "Pilot", task: "t", projectPath: "/p",
            claude: ClaudeRunOptions(model: "claude-haiku-5-5", allowedTools: ["WebFetch"], maxTurns: 5),
            variants: [ExperimentVariant(key: "control", name: "c"), ExperimentVariant(key: "s", name: "s", profile: "pv_abc")], trialsPerVariant: 3,
            judge: JudgeConfig(model: "claude-sonnet-5-5"))
        original.claude.disallowedTools = ["Bash"]
        original.claude.timeoutSeconds = 99
        original.seed = 42
        let copy = original.duplicate
        #expect(copy.name == "Pilot (copy)" && copy.seed == nil && copy.variants == original.variants)

        var f = FormLogic.ExperimentForm(name: copy.name, task: "new task", project: "/p", claudeModel: "claude-haiku-5-5", allowedTools: "WebFetch,Read",
                                         maxTurns: 5, trials: 10, useJudge: true, variants: copy.variants, base: copy)
        var d = FormLogic.experimentDefinition(f)
        #expect(d.task == "new task" && d.trialsPerVariant == 10 && d.claude.allowedTools == ["WebFetch", "Read"])
        #expect(d.claude.disallowedTools == ["Bash"] && d.claude.timeoutSeconds == 99 && d.judge?.model == "claude-sonnet-5-5")
        f.useJudge = false
        d = FormLogic.experimentDefinition(f)
        #expect(d.judge == nil)
    }

    @Test func purgeMessageCountsWhatGoes() {
        let m = FormLogic.purgeMessage(PurgeResult(dryRun: true, sessions: 2, experiments: 1, runs: 3, trialSessions: 6, decisions: 40, exchanges: 12), days: 30)
        #expect(m.contains("older than 30 days") && m.contains("• 2 sessions") && m.contains("• 1 experiment with 3 runs and 6 trial sessions"))
        #expect(m.contains("can't be undone"))
    }

    @Test func archiveMessageShowsWhatMoves() {
        let refs = [
            ProfileReference(kind: .launcher, label: "Start", byName: true),
            ProfileReference(kind: .folderDefault, label: "/pinned", byName: false, pinned: true),
            ProfileReference(kind: .experiment, label: "Exp", byName: true),
        ]
        #expect(FormLogic.movableReferences(refs) == 1)
        let m = FormLogic.archiveProfileMessage(refs, movingTo: "Other")
        #expect(m.contains("These will use “Other” instead:\n• Launcher “Start”"))
        #expect(m.contains("won't find it any more:\n• Experiment “Exp”"))
        #expect(!m.contains("pinned"))
    }

    @Test func upsertReplacesTheSameNameAndKeepsItsId() {
        let a = Launcher(id: "a", name: "One", folder: "/a")
        let list = FormLogic.upsert(Launcher(id: "new", name: "one", folder: "/b"), into: [a])
        #expect(list.count == 1 && list[0].id == "a" && list[0].folder == "/b")
        #expect(FormLogic.upsert(Launcher(name: "Two", folder: "/c"), into: [a]).count == 2)
    }

    @Test func installedHookFillsTheFormBack() throws {
        var form = FormLogic.SessionForm(folder: "/p")
        form.profile = "Docs steer"
        form.prompt = "Say it's v2"
        form.promptTools = "WebFetch,Read"
        form.taskContext = true
        form.lockdown = .network
        let command = try HookInstaller.inlineCommand(cli: "/x/diorama", config: FormLogic.hookConfig(form))
        let back = FormLogic.form(fromHook: try #require(HookInstaller.config(in: command)), folder: "/p")
        #expect(back == form)
        // A CLI install may name the profile by id; the form uses names.
        let byId = FormLogic.form(fromHook: HookConfig(profile: "prof_1"), folder: "/p", profileNames: ["prof_1": "Docs steer"])
        #expect(byId.profile == "Docs steer" && byId.prompt.isEmpty && byId.lockdown == .none)
    }
}
