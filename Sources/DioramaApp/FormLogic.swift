import DioramaCore
import Foundation

/// Pure logic behind the app's forms, kept out of the views so it can be unit-tested.
enum FormLogic {
    /// The confirmation shown before purging archived data.
    static func purgeMessage(_ p: PurgeResult, days: Int) -> String {
        var lines = ["Archived and older than \(days) days:"]
        if p.sessions > 0 { lines.append("• \(Fmt.plural(p.sessions, "session"))") }
        if p.experiments > 0 { lines.append("• \(Fmt.plural(p.experiments, "experiment")) with \(Fmt.plural(p.runs, "run")) and \(Fmt.plural(p.trialSessions, "trial session"))") }
        lines.append("\(Fmt.plural(p.exchanges, "request")) and \(Fmt.plural(p.decisions, "tool result")) go with them. This can't be undone.")
        return lines.joined(separator: "\n")
    }

    /// Folder defaults, launchers and hooks: the references a move can change.
    static func movableReferences(_ refs: [ProfileReference]) -> Int {
        refs.filter { [.folderDefault, .launcher, .hook].contains($0.kind) && $0.pinned != true }.count
    }

    /// The confirmation shown before archiving a profile: what keeps working, and what names it
    /// by name and so stops finding it (unless it's moved to `movingTo`).
    static func archiveProfileMessage(_ refs: [ProfileReference], movingTo: String? = nil) -> String {
        var lines = ["It leaves the list and the pickers. Its versions stay, so past sessions, experiment results and anything that uses its id keep working. You can unarchive it later."]
        let movable: Set<ProfileReference.Kind> = [.folderDefault, .launcher, .hook]
        if let target = movingTo {
            let moving = refs.filter { movable.contains($0.kind) && $0.pinned != true }
            if !moving.isEmpty {
                lines.append("These will use “\(target)” instead:")
                lines += moving.map { "• \(referenceText($0))" }
            }
        }
        let broken = refs.filter { $0.byName && (movingTo == nil || !movable.contains($0.kind)) }
        if !broken.isEmpty {
            lines.append("These name it by name and won't find it any more:")
            lines += broken.map { "• \(referenceText($0))" }
        }
        if let file = refs.first(where: { $0.kind == .syncedFile }) {
            lines.append("It's synced from \(file.label). If that file changes, it comes back as a new profile; remove the file or stop watching its folder to prevent that.")
        }
        return lines.joined(separator: "\n")
    }

    static func referenceText(_ r: ProfileReference) -> String {
        switch r.kind {
        case .folderDefault: "Folder default for \((r.label as NSString).abbreviatingWithTildeInPath)"
        case .launcher: "Launcher “\(r.label)”"
        case .hook: "Hook in \((r.label as NSString).abbreviatingWithTildeInPath)"
        case .syncedFile: "File \((r.label as NSString).abbreviatingWithTildeInPath)"
        case .experiment: "Experiment “\(r.label)” (new runs)"
        }
    }

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
        var agent = CodingAgent.claude
    }

    /// The shell command that starts a routed session (every value shell-quoted).
    static func sessionCommand(_ f: SessionForm, cli: String) -> String {
        var parts = ["cd", shellQuote(f.folder), "&&", shellQuote(cli), "run"]
        if f.agent == .opencode { parts += ["--agent", "opencode"] }
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

    /// A launcher saving this form (the launcher's name also names its sessions).
    static func launcher(_ f: SessionForm, name: String, id: String? = nil) -> Launcher {
        let prompt = f.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var l = Launcher(name: name, folder: f.folder, profile: f.profile.isEmpty ? nil : f.profile, prompt: prompt.isEmpty ? nil : f.prompt,
                         promptTools: parseList(f.promptTools), taskContext: f.taskContext, pageStage: f.pageStage, lockdown: f.lockdown, claudeArgs: f.claudeArgs,
                         agent: f.agent == .opencode ? .opencode : nil)
        if let id { l.id = id }
        return l
    }

    /// The shell command that starts a launcher's session in its folder.
    static func launchCommand(_ l: Launcher, cli: String) -> String {
        let args = l.runArguments
        let split = args.firstIndex(of: "--") ?? args.endIndex
        // Claude Code's extra arguments stay unquoted, as typed (like the New Session form).
        let quoted = args[..<split].map { $0 == "run" ? $0 : shellQuote($0) } + (split < args.endIndex ? ["--", l.claudeArgs] : [])
        return (["cd", shellQuote(l.folder), "&&", shellQuote(cli)] + quoted).joined(separator: " ")
    }

    /// Adds `l`, replacing a launcher with the same name (case-insensitive).
    static func upsert(_ l: Launcher, into list: [Launcher]) -> [Launcher] {
        guard let i = list.firstIndex(where: { $0.name.caseInsensitiveCompare(l.name) == .orderedSame }) else { return list + [l] }
        var out = list
        var replaced = l
        replaced.id = list[i].id
        out[i] = replaced
        return out
    }

    /// Hook mode's configuration from the same form (hook mode has no page stage or name).
    static func hookConfig(_ f: SessionForm) -> HookConfig {
        let prompt = f.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return HookConfig(
            profile: f.profile.isEmpty ? nil : f.profile,
            prompt: prompt.isEmpty ? nil : SessionPrompt(text: f.prompt, tools: parseList(f.promptTools), context: f.taskContext ? .task : .none),
            lockdown: f.lockdown == .none ? nil : f.lockdown)
    }

    /// The form an installed hook was made from (the reverse of `hookConfig`), so it can be
    /// edited. `profileNames` maps a profile id (CLI installs may use one) to its name.
    static func form(fromHook c: HookConfig, folder: String, profileNames: [String: String] = [:]) -> SessionForm {
        var f = SessionForm(folder: folder)
        f.profile = c.profile.map { profileNames[$0] ?? $0 } ?? ""
        if let p = c.prompt {
            f.prompt = p.text
            f.promptTools = p.tools.joined(separator: ",")
            f.taskContext = p.context == .task
        }
        f.lockdown = c.lockdown ?? .none
        return f
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
        var agent = CodingAgent.claude
        var variants: [ExperimentVariant] = [
            ExperimentVariant(key: "control", name: "Unmodified"),
            ExperimentVariant(key: "steered", name: "Steered", prompt: SessionPrompt(text: "")),
        ]
        /// The definition the form was filled from (a duplicate or a session draft): settings the form
        /// doesn't show, such as disallowed tools or the judge's model, are kept from it.
        var base: ExperimentDefinition?
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
        let fresh = ExperimentDefinition(
            name: f.name, task: f.task, projectPath: f.project,
            claude: ClaudeRunOptions(model: f.claudeModel.isEmpty ? nil : f.claudeModel, allowedTools: tools, maxTurns: f.maxTurns,
                                     maxBudgetUSD: f.agent == .opencode ? nil : f.budget, isolateConfiguration: f.isolate),
            variants: variants, trialsPerVariant: f.trials, concurrency: f.concurrency, treatment: f.frozen ? .frozen : .fresh,
            judge: f.useJudge ? JudgeConfig() : nil, agent: f.agent == .opencode ? .opencode : nil)
        guard var d = f.base else { return fresh }
        d.name = fresh.name
        d.task = fresh.task
        d.projectPath = fresh.projectPath
        d.claude.model = fresh.claude.model
        d.claude.allowedTools = fresh.claude.allowedTools
        d.claude.maxTurns = fresh.claude.maxTurns
        d.claude.maxBudgetUSD = fresh.claude.maxBudgetUSD
        d.claude.isolateConfiguration = fresh.claude.isolateConfiguration
        d.variants = fresh.variants
        d.trialsPerVariant = fresh.trialsPerVariant
        d.concurrency = fresh.concurrency
        d.treatment = fresh.treatment
        d.judge = f.useJudge ? (d.judge ?? JudgeConfig()) : nil
        d.agent = fresh.agent
        return d
    }

    /// Problems that would make a rule silently never match or do nothing.
    static func ruleProblems(_ rule: Rule) -> [String] {
        var out: [String] = []
        if rule.match.tools.isEmpty { out.append("No tools: the rule never matches.") }
        if let c = rule.match.classifier {
            if c.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append("The classifier needs a yes/no question.") }
            if rule.isLocal { out.append("Redaction and replacement rules can't use a classifier (they run locally, without a model).") }
        }
        if let items = rule.replace {
            if items.isEmpty { out.append("Nothing to replace: add a find → with.") }
            for (i, item) in items.enumerated() {
                if item.find.isEmpty { out.append("Replacement \(i + 1) has nothing to find.") }
                else if item.expression == nil { out.append("Replacement \(i + 1) has an invalid regex.") }
            }
        } else if let spec = rule.redact {
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
