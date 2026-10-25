import AppKit
import DioramaCore
import SwiftUI
import UniformTypeIdentifiers

struct ExperimentsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: String?
    @State private var showNew = false

    var body: some View {
        HSplitView {
            List(selection: $selection) {
                ForEach(model.experiments) { e in
                    Section(e.name) {
                        if e.runs.isEmpty { Text("No runs yet").font(.caption).foregroundStyle(.secondary) }
                        ForEach(e.runs) { r in
                            HStack {
                                Badge(text: r.status.rawValue, color: r.status == .completed ? .green : (r.status == .running ? .blue : .secondary))
                                Text("\(r.trialsDone)/\(r.trialsTotal)").font(.caption)
                                Text(r.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }.tag("run:" + r.id)
                        }
                        Text("Definition & new run").font(.caption).foregroundStyle(.blue).tag("exp:" + e.id)
                    }
                }
            }
            .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
            .overlay {
                if model.experiments.isEmpty {
                    ContentUnavailableView("No experiments", systemImage: "flask", description: Text("Compare an unmodified control with steered variants over repeated trials."))
                }
            }
            Group {
                if let s = selection, s.hasPrefix("run:") {
                    RunView(runId: String(s.dropFirst(4))).id(s)
                } else if let s = selection, s.hasPrefix("exp:"), let e = model.experiments.first(where: { $0.id == s.dropFirst(4) }) {
                    ExperimentSummaryView(experiment: e, onRunStarted: { selection = "run:" + $0 })
                } else {
                    ContentUnavailableView("Select an experiment run", systemImage: "chart.bar.xaxis")
                }
            }
            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItem { Button { showNew = true } label: { Label("New Experiment", systemImage: "plus") } }
        }
        .sheet(isPresented: $showNew) { NewExperimentSheet { selection = "exp:" + $0 } }
        .navigationTitle("Experiments")
        .task { if model.snapshotDir != nil, selection == nil, let r = model.experiments.first?.runs.first { selection = "run:" + r.id } }
    }
}

struct ExperimentSummaryView: View {
    @Environment(AppModel.self) private var model
    let experiment: ExperimentInfo
    let onRunStarted: (String) -> Void
    @State private var pending: RunSummary?

    var body: some View {
        let d = experiment.definition
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(experiment.name).font(.title2.bold())
                Text("Definition hash \(experiment.definitionHash)").font(.caption.monospaced()).foregroundStyle(.secondary)
                LabeledContent("Task") { Text(d.task).textSelection(.enabled) }
                LabeledContent("Project") { Text(d.projectPath).font(.caption) }
                LabeledContent("Claude Code") {
                    Text("model \(d.claude.model ?? "default") · tools \(d.claude.allowedTools.joined(separator: ", ")) · max turns \(d.claude.maxTurns.map(String.init) ?? "—") · isolated config \(d.claude.isolateConfiguration ? "yes" : "no")").font(.caption)
                }
                LabeledContent("Trials") { Text("\(d.trialsPerVariant) per variant · concurrency \(d.concurrency) · treatment \(d.treatment.rawValue)") }
                GroupBox("Variants") {
                    VStack(alignment: .leading) {
                        ForEach(d.variants, id: \.key) { v in
                            HStack(alignment: .top) {
                                Text(v.key).bold()
                                if v.isControl { Badge(text: "control", color: .green) }
                                Text([v.profile.map { "profile: \($0)" }, v.prompt.map { "prompt: \($0.text)" }, v.lockdown == .none ? nil : "lockdown"].compactMap { $0 }.joined(separator: " · ")).font(.caption)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("Estimate cost & run…") {
                    Task { pending = await model.perform { try await $0.prepareRun(experimentId: experiment.id) } }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .sheet(item: $pending) { run in
            EstimateSheet(run: run, experiment: experiment) { started in
                pending = nil
                if let started { onRunStarted(started.id) }
            }
        }
    }
}

struct EstimateSheet: View {
    @Environment(AppModel.self) private var model
    let run: RunSummary
    let experiment: ExperimentInfo
    let done: (RunSummary?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Confirm experiment run").font(.title2.bold())
            if let e = run.estimate {
                Text("\(e.trials) Claude Code runs (\(experiment.definition.variants.count) variants × \(experiment.definition.trialsPerVariant)).")
                Text(String(format: "Estimated total: $%.2f – $%.2f", e.totalLowUSD, e.totalHighUSD)).font(.title3.bold())
                Text(String(format: "Claude Code: $%.2f – $%.2f per trial — %@", e.perTrialLowUSD, e.perTrialHighUSD, e.basis)).font(.callout)
                Text(String(format: "Rewrite agent: $%.3f – $%.3f", e.rewriteLowUSD, e.rewriteHighUSD)).font(.callout)
                ForEach(e.notes, id: \.self) { Text("• " + $0).font(.caption).foregroundStyle(.secondary) }
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    Task {
                        _ = await model.perform { try await $0.cancelRun(run.id) }
                        await model.refreshExperiments()
                        done(nil)
                    }
                }
                Button("Start run") {
                    Task {
                        let r = await model.perform { try await $0.startRun(run.id, confirmationToken: run.estimate?.confirmationToken ?? "") }
                        await model.refreshExperiments()
                        done(r)
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 520)
    }
}

struct RunView: View {
    @Environment(AppModel.self) private var model
    let runId: String
    @State private var comparison: RunComparison?

    var body: some View {
        ScrollView {
            if let c = comparison {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Run \(c.run.id)").font(.title3.bold())
                        Badge(text: c.run.status.rawValue, color: c.run.status == .completed ? .green : .blue)
                        Text("\(c.run.trialsDone)/\(c.run.trialsTotal) trials · seed \(String(c.run.seed))").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if c.run.status == .running {
                            Button("Cancel run", role: .destructive) { Task { _ = await model.perform { try await $0.cancelRun(runId) } } }
                        }
                        Menu("Export") {
                            Button("Markdown report…") { Task { await export("md") } }
                            Button("JSON bundle…") { Task { await export("json") } }
                        }.fixedSize()
                    }
                    if c.run.status == .running { ProgressView(value: Double(c.run.trialsDone), total: Double(max(c.run.trialsTotal, 1))) }
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(c.caveats, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                    }
                    GroupBox("Observed facts") { FactsTable(variants: c.variants) }
                    GroupBox {
                        HeuristicsTable(variants: c.variants)
                    } label: {
                        Label("Heuristic signals — pattern-matched interpretations, not facts", systemImage: "wand.and.stars")
                    }
                    GroupBox("Trials") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(c.trials) { t in TrialRow(trial: t) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            } else {
                ProgressView().padding()
            }
        }
        .task(id: model.eventTick) { comparison = await model.perform { try await $0.comparison(runId) } }
    }

    func export(_ format: String) async {
        guard let text = await model.perform({ try await $0.report(runId, format: format) }) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "diorama-\(runId).\(format)"
        panel.allowedContentTypes = [format == "md" ? UTType(filenameExtension: "md") ?? .plainText : .json]
        if panel.runModal() == .OK, let url = panel.url {
            do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { model.report(error) }
        }
    }
}

struct FactsTable: View {
    let variants: [VariantComparison]
    func num(_ s: NumericStat, _ f: String = "%.1f") -> String { s.n == 0 ? "—" : String(format: "\(f) ± \(f)", s.mean, s.stdDev) }
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                ForEach(["Variant", "Valid", "Errors", "Turns", "Duration", "Claude $", "Rewrite $", "Rewrites", "Distinct outputs"], id: \.self) { Text($0).font(.caption.bold()) }
            }
            Divider()
            ForEach(variants, id: \.variantKey) { v in
                GridRow {
                    HStack { Text(v.variantKey).bold(); if v.isControl { Badge(text: "control", color: .green) } }
                    Text("\(v.validTrials)/\(v.trials)")
                    Text("\(v.errorRate.count)")
                    Text(num(v.turns))
                    Text(v.durationMs.n == 0 ? "—" : String(format: "%.1fs", v.durationMs.mean / 1000))
                    Text(num(v.claudeCostUSD, "%.3f"))
                    Text(num(v.rewriteCostUSD, "%.4f"))
                    Text(num(v.rewritesApplied))
                    Text("\(v.distinctFinalOutputs)")
                }.font(.callout)
            }
        }
        .padding(6)
    }
}

struct HeuristicsTable: View {
    let variants: [VariantComparison]
    var hasJudge: Bool { variants.contains { $0.judgeAdopted != nil } }
    func p(_ s: ProportionStat) -> String { s.total == 0 ? "—" : String(format: "%d/%d  (95%% CI %.0f–%.0f%%)", s.count, s.total, s.interval95.low * 100, s.interval95.high * 100) }
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                ForEach(["Variant", "Echoed rewritten content", "Flagged suspicion", "Tried to verify"] + (hasJudge ? ["LLM judge: adopted"] : []), id: \.self) { Text($0).font(.caption.bold()) }
            }
            Divider()
            ForEach(variants, id: \.variantKey) { v in
                GridRow {
                    Text(v.variantKey).bold()
                    Text(p(v.echoedRewrittenContent))
                    Text(p(v.flaggedSuspicion))
                    Text(p(v.attemptedVerification))
                    if hasJudge { Text(v.judgeAdopted.map(p) ?? "—") }
                }.font(.callout)
            }
        }
        .padding(6)
    }
}

struct TrialRow: View {
    @Environment(AppModel.self) private var model
    let trial: TrialInfo
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                if let f = trial.facts {
                    Text("Final output").font(.caption.bold())
                    MonoBlock(text: f.finalOutput).frame(minHeight: 60, maxHeight: 200)
                    Text("Tools: " + f.toolCalls.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: ", ")).font(.caption)
                    if !f.filesChanged.isEmpty { Text("Files changed: " + f.filesChanged.joined(separator: ", ")).font(.caption) }
                }
                if let s = trial.signals, !s.evidence.isEmpty {
                    Text("Heuristic evidence").font(.caption.bold())
                    ForEach(s.evidence, id: \.self) { Text("• " + $0).font(.caption).foregroundStyle(.secondary) }
                }
                if let m = trial.manifest {
                    Text("Manifest: Claude Code \(m.claudeVersion ?? "?") · \(m.arguments.joined(separator: " "))").font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let sid = trial.sessionId { Text("Session \(sid) (see Sessions → Trials)").font(.caption2).foregroundStyle(.secondary) }
            }
        } label: {
            HStack {
                Text("#\(trial.order + 1)").font(.caption.monospaced())
                Text(trial.variantKey).bold()
                Badge(text: trial.status.rawValue, color: trial.status == .succeeded ? .green : (trial.status == .running ? .blue : .red))
                if let f = trial.facts {
                    Text("\(f.numTurns ?? 0) turns · \(formatMoney(f.claudeCostUSD)) · \(f.rewritesApplied) rewrites").font(.caption).foregroundStyle(.secondary)
                }
                if let e = trial.error { Text(e).font(.caption).foregroundStyle(.red).lineLimit(1) }
            }
        }
    }
}


struct NewExperimentSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let created: (String) -> Void
    @State private var name = "My experiment"
    @State private var task = ""
    @State private var project = FileManager.default.homeDirectoryForCurrentUser.path
    @State private var claudeModel = ""
    @State private var allowedTools = "WebFetch,WebSearch,Read"
    @State private var maxTurns = 15
    @State private var budget = 2.0
    @State private var trials = 3
    @State private var concurrency = 2
    @State private var frozen = true
    @State private var isolate = true
    @State private var useJudge = false
    @State private var variants: [ExperimentVariant] = [
        ExperimentVariant(key: "control", name: "Unmodified"),
        ExperimentVariant(key: "steered", name: "Steered", prompt: SessionPrompt(text: "")),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New experiment").font(.title2.bold())
            Form {
                TextField("Name", text: $name)
                VStack(alignment: .leading) {
                    Text("Task given to Claude Code")
                    TextEditor(text: $task).frame(height: 70).overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                }
                HStack {
                    TextField("Project folder (copied per trial)", text: $project)
                    Button("Choose…") { if let f = chooseFolder() { project = f } }
                }
                TextField("Claude Code model (blank = default)", text: $claudeModel)
                TextField("Allowed tools", text: $allowedTools)
                Stepper("Max turns: \(maxTurns)", value: $maxTurns, in: 1...200)
                Stepper(String(format: "Max budget per trial: $%.2f", budget), value: $budget, in: 0.1...50, step: 0.5)
                Stepper("Trials per variant: \(trials)", value: $trials, in: 1...200)
                Stepper("Concurrency: \(concurrency)", value: $concurrency, in: 1...8)
                Toggle("Frozen treatment (reuse identical rewrites across trials)", isOn: $frozen)
                Toggle("Isolate Claude Code configuration (no user settings/MCP)", isOn: $isolate)
                Toggle("LLM judge after the run (heuristic; uses your API key)", isOn: $useJudge)
                Section("Variants") {
                    ForEach($variants, id: \.key) { $v in
                        HStack(alignment: .top) {
                            TextField("key", text: $v.key).frame(width: 90)
                            Picker("", selection: Binding(get: { v.profile ?? "" }, set: { v.profile = $0.isEmpty ? nil : $0 })) {
                                Text("No profile").tag("")
                                ForEach(model.profiles) { Text($0.name).tag($0.name) }
                            }.frame(width: 170)
                            TextField("Session prompt (blank = none)", text: Binding(
                                get: { v.prompt?.text ?? "" },
                                set: { v.prompt = $0.isEmpty ? nil : SessionPrompt(text: $0, tools: allowedTools.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }))
                        }
                    }
                    Button("Add variant") { variants.append(ExperimentVariant(key: "v\(variants.count + 1)", name: "Variant \(variants.count + 1)")) }
                    Text("A variant with no profile and no prompt is the unmodified control. One is required.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    Task {
                        let def = FormLogic.experimentDefinition(FormLogic.ExperimentForm(
                            name: name, task: task, project: project, claudeModel: claudeModel, allowedTools: allowedTools, maxTurns: maxTurns,
                            budget: budget, trials: trials, concurrency: concurrency, frozen: frozen, isolate: isolate, useJudge: useJudge,
                            variants: variants))
                        if let e = await model.perform({ try await $0.createExperiment(def) }) {
                            await model.refreshExperiments()
                            created(e.id)
                            dismiss()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 680, height: 720)
    }
}
