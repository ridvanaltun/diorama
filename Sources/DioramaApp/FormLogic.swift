import DioramaCore
import Foundation

/// Pure logic behind the app's forms, kept out of the views so it can be unit-tested.
enum FormLogic {
    struct SessionForm: Equatable {
        var folder: String
        var name = ""
        var profile = ""
        var prompt = ""
        var promptTools = SessionPrompt.defaultTools.joined(separator: ",")
        var taskContext = false
        var pageStage = false
        var lockdown = LockdownPreset.none
        var claudeArgs = ""
    }

    /// The shell command that starts a routed session (every value shell-quoted).
    static func sessionCommand(_ f: SessionForm, cli: String) -> String {
        var parts = ["cd", shellQuote(f.folder), "&&", shellQuote(cli), "run"]
        if !f.name.isEmpty { parts += ["--name", shellQuote(f.name)] }
        if !f.profile.isEmpty { parts += ["--profile", shellQuote(f.profile)] }
        if !f.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts += ["--prompt", shellQuote(f.prompt)]
            if f.pageStage {
                parts += ["--prompt-stage", "page"]
            } else {
                parts += ["--prompt-tools", shellQuote(f.promptTools)]
            }
            if f.taskContext { parts += ["--prompt-context", "task"] }
        }
        if f.lockdown != .none { parts += ["--lockdown", f.lockdown.rawValue] }
        if !f.claudeArgs.trimmingCharacters(in: .whitespaces).isEmpty { parts += ["--", f.claudeArgs] }
        return parts.joined(separator: " ")
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func parseList(_ s: String) -> [String] {
        s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func formatInputPatterns(_ d: [String: String]) -> String {
        d.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    }

    /// `field=regex` per line; the first `=` separates (regexes may contain `=`).
    static func parseInputPatterns(_ text: String) -> [String: String] {
        var d: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1).map(String.init)
            let key = kv.first?.trimmingCharacters(in: .whitespaces) ?? ""
            if kv.count == 2, !key.isEmpty { d[key] = kv[1] }
        }
        return d
    }

    struct ExperimentForm: Equatable {
        var name = "My experiment"
        var task = ""
        var project: String
        var claudeModel = ""
        var allowedTools = "WebFetch,WebSearch,Read"
        var maxTurns = 15
        var budget = 2.0
        var trials = 3
        var concurrency = 2
        var frozen = true
        var isolate = true
        var useJudge = false
        var variants: [ExperimentVariant] = [
            ExperimentVariant(key: "control", name: "Unmodified"),
            ExperimentVariant(key: "steered", name: "Steered", prompt: SessionPrompt(text: "")),
        ]
    }

    static func experimentDefinition(_ f: ExperimentForm) -> ExperimentDefinition {
        let tools = parseList(f.allowedTools)
        let variants = f.variants.map { v -> ExperimentVariant in
            var v = v
            v.name = v.key
            // An empty prompt means "no prompt" (otherwise the variant would never be the control).
            if let p = v.prompt, p.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { v.prompt = nil }
            return v
        }
        return ExperimentDefinition(
            name: f.name, task: f.task, projectPath: f.project,
            claude: ClaudeRunOptions(model: f.claudeModel.isEmpty ? nil : f.claudeModel, allowedTools: tools, maxTurns: f.maxTurns, maxBudgetUSD: f.budget, isolateConfiguration: f.isolate),
            variants: variants, trialsPerVariant: f.trials, concurrency: f.concurrency, treatment: f.frozen ? .frozen : .fresh,
            judge: f.useJudge ? JudgeConfig() : nil)
    }
}
