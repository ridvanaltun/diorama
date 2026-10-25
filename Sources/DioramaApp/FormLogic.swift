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

    /// Hook mode's configuration from the same form (hook mode has no page stage, name or lockdown).
    static func hookConfig(_ f: SessionForm) -> HookConfig {
        let prompt = f.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return HookConfig(
            profile: f.profile.isEmpty ? nil : f.profile,
            prompt: prompt.isEmpty ? nil : SessionPrompt(text: f.prompt, tools: parseList(f.promptTools), context: f.taskContext ? .task : .none))
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

    /// Problems that would make a rule silently never match or do nothing.
    static func ruleProblems(_ rule: Rule) -> [String] {
        var out: [String] = []
        if rule.match.tools.isEmpty { out.append("No tools: the rule never matches.") }
        if let c = rule.match.classifier {
            if c.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append("The classifier needs a yes/no question.") }
            if rule.isRedaction { out.append("Redaction rules can't use a classifier (they run locally, without a model).") }
        }
        if let spec = rule.redact {
            if spec.presets.isEmpty && spec.patterns.isEmpty { out.append("Nothing to redact: pick a preset or add a pattern.") }
            for p in spec.patterns where (try? NSRegularExpression(pattern: p)) == nil { out.append("Redaction pattern “\(p)” is an invalid regex.") }
        } else if rule.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append("No instructions for the rewrite agent.")
        }
        if let c = rule.match.content, (try? Regex(c)) == nil { out.append("Content regex is invalid.") }
        if let s = rule.match.sample, !(s > 0 && s <= 1) { out.append("The sample must be between 1% and 100%.") }
        for (field, pattern) in rule.match.input.sorted(by: { $0.key < $1.key }) where (try? Regex(pattern)) == nil {
            out.append("Input pattern for “\(field)” is an invalid regex.")
        }
        return out
    }
}

extension FormLogic {
    struct ImportError: Error, CustomStringConvertible {
        let description: String
    }

    /// A profile from a file: what `Export…` and `diorama profiles export` write, or any JSON object
    /// with a `profile` field (a saved version). A taken name gets " (2)", " (3)", … appended.
    static func importedProfile(_ data: Data, existingNames: Set<String>) throws -> Profile {
        let decoder = DioramaCoding.decoder
        var profile: Profile
        if let p = try? decoder.decode(Profile.self, from: data), !p.name.isEmpty {
            profile = p
        } else if let wrapped = try? decoder.decode(Wrapped.self, from: data) {
            profile = wrapped.profile
        } else {
            throw ImportError(description: "This file isn't a Diorama profile (expected JSON with a name and rules, as written by Export…).")
        }
        profile.name = uniqueName(profile.name.trimmingCharacters(in: .whitespaces), existingNames)
        return profile
    }

    private struct Wrapped: Decodable { var profile: Profile }

    static func uniqueName(_ name: String, _ taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        var n = 2
        while taken.contains("\(name) (\(n))") { n += 1 }
        return "\(name) (\(n))"
    }

    static func exportFileName(_ profileName: String) -> String {
        let safe = profileName.map { "/:\\".contains($0) ? "-" : $0 }
        return "\(String(safe)).diorama-profile.json"
    }
}
