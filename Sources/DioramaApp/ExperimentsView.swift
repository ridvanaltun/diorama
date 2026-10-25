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
                    Section {
                        Label("Definition & new run", systemImage: "doc.text.magnifyingglass").tag("exp:" + e.id)
                        if e.runs.filter({ $0.status == .completed }).count >= 2 {
                            Label("All runs (pooled)", systemImage: "square.stack.3d.up").tag("pool:" + e.id)
                        }
                        ForEach(e.runs) { r in RunRow(run: r).tag("run:" + r.id) }
                    } header: {
                        HStack {
                            Text(e.name)
                            Spacer()
                            Text(Fmt.plural(e.runs.count, "run")).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
            .overlay {
                if model.experiments.isEmpty {
                    ContentUnavailableView {
                        Label("No experiments", systemImage: "flask")
                    } description: {
                        Text("Run the same task many times — once unmodified, once steered — and compare what Claude Code did.")
                    } actions: {
                        Button("New Experiment") { showNew = true }
                    }
                }
            }
            Group {
                if let s = selection, s.hasPrefix("run:") {
                    RunView(runId: String(s.dropFirst(4))).id(s)
                } else if let s = selection, s.hasPrefix("pool:") {
                    RunView(source: .pooled(experimentId: String(s.dropFirst(5)))).id(s)
                } else if let s = selection, s.hasPrefix("exp:"), let e = model.experiments.first(where: { $0.id == s.dropFirst(4) }) {
                    ExperimentSummaryView(experiment: e, onRunStarted: { selection = "run:" + $0 })
                } else {
                    ContentUnavailableView("Select an experiment run", systemImage: "chart.bar.xaxis",
                                           description: Text("Facts and heuristic signals per variant, with every trial's record."))
                }
            }
            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItem { Button { showNew = true } label: { Label("New Experiment", systemImage: "plus") } }
        }
        .sheet(isPresented: $showNew) { NewExperimentSheet { selection = "exp:" + $0 } }
        .onChange(of: model.focusExperimentId, initial: true) { _, id in
            guard let id else { return }
            selection = "exp:" + id
            model.focusExperimentId = nil
        }
        .onChange(of: model.focusRunId, initial: true) { _, id in
            guard let id else { return }
            selection = "run:" + id
            model.focusRunId = nil
        }
        .navigationTitle("Experiments")
        .task { if model.snapshotDir != nil, selection == nil, let r = model.experiments.first?.runs.first { selection = "run:" + r.id } }
    }
}

struct RunRow: View {
    let run: RunSummary
    var body: some View {
        HStack(spacing: 8) {
            RunStatusIcon(status: run.status)
            VStack(alignment: .leading, spacing: 1) {
                Text(Fmt.runTitle(run.createdAt)).lineLimit(1)
                Text(run.status == .running ? "\(run.trialsDone) of \(Fmt.plural(run.trialsTotal, "trial"))" : "\(Fmt.plural(run.trialsTotal, "trial")) · \(run.status.rawValue)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct RunStatusIcon: View {
    let status: RunStatus
    var body: some View {
        switch status {
        case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .running: ProgressView().controlSize(.small)
        case .pending: Image(systemName: "clock").foregroundStyle(.secondary)
        case .cancelled: Image(systemName: "stop.circle").foregroundStyle(.secondary)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
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
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text(experiment.name).font(.title2.bold())
                    Spacer()
                    Button {
                        Task { pending = await model.perform { try await $0.prepareRun(experimentId: experiment.id) } }
                    } label: {
                        Label("Estimate cost & run…", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Task").font(.headline)
                    Text(d.task).textSelection(.enabled).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow { Text("Project").foregroundStyle(.secondary); Text(Fmt.shortPath(d.projectPath)).textSelection(.enabled) }
                    GridRow { Text("Model").foregroundStyle(.secondary); Text(d.claude.model ?? "Claude Code default") }
                    GridRow { Text("Allowed tools").foregroundStyle(.secondary); Text(d.claude.allowedTools.joined(separator: ", ")) }
                    GridRow { Text("Trials").foregroundStyle(.secondary); Text("\(d.trialsPerVariant) per variant, \(d.concurrency) at a time") }
                    GridRow { Text("Treatment").foregroundStyle(.secondary); Text(d.treatment == .frozen ? "Frozen — identical rewrites reused across trials" : "Fresh rewrite in every trial") }
                    GridRow { Text("Limits").foregroundStyle(.secondary); Text("\(d.claude.maxTurns.map { "\($0) turns" } ?? "no turn limit") · \(d.claude.maxBudgetUSD.map { Fmt.money($0) + " per trial" } ?? "no budget limit")") }
                    GridRow { Text("Configuration").foregroundStyle(.secondary); Text(d.claude.isolateConfiguration ? "Isolated (no user settings or MCP servers)" : "User's Claude Code configuration") }
                    if let j = d.judge { GridRow { Text("LLM judge").foregroundStyle(.secondary); Text(j.model) } }
                }
                .font(.callout)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Variants").font(.headline)
                    ForEach(d.variants, id: \.key) { v in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: v.isControl ? "circle.dashed" : "wand.and.stars").foregroundStyle(v.isControl ? .green : .purple).frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack { Text(v.name.isEmpty ? v.key : v.name).bold(); if v.isControl { Badge(text: "control", color: .green) } }
                                Text(variantDescription(v)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                Text("Definition \(String(experiment.definitionHash.prefix(12)))").font(.caption2.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
            }
            .padding(20)
        }
        .sheet(item: $pending) { run in
            EstimateSheet(run: run, experiment: experiment) { started in
                pending = nil
                if let started { onRunStarted(started.id) }
            }
        }
    }

    func variantDescription(_ v: ExperimentVariant) -> String {
        let parts = [v.profile.map { $0.hasPrefix("pv_") ? "Profile version pinned (\(v.name))" : "Profile “\($0)”" }, v.prompt.map { "Prompt: \($0.text)" }, v.lockdown == .none ? nil : "Network lockdown"].compactMap { $0 }
        return parts.isEmpty ? "Unmodified — tool results forwarded as-is" : parts.joined(separator: " · ")
    }
}

struct EstimateSheet: View {
    @Environment(AppModel.self) private var model
    let run: RunSummary
    let experiment: ExperimentInfo
    let done: (RunSummary?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Confirm experiment run").font(.title2.bold())
            if let e = run.estimate {
                Text("\(Fmt.plural(e.trials, "Claude Code run")) (\(Fmt.plural(experiment.definition.variants.count, "variant")) × \(experiment.definition.trialsPerVariant)).")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Estimated total").font(.caption).foregroundStyle(.secondary)
                    Text("\(Fmt.money(e.totalLowUSD)) – \(Fmt.money(e.totalHighUSD))").font(.title.bold().monospacedDigit())
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow { Text("Claude Code, per trial").foregroundStyle(.secondary); Text("\(Fmt.money(e.perTrialLowUSD)) – \(Fmt.money(e.perTrialHighUSD))") }
                    GridRow { Text("Rewrite agent, total").foregroundStyle(.secondary); Text("\(Fmt.money(e.rewriteLowUSD)) – \(Fmt.money(e.rewriteHighUSD))") }
                }
                .font(.callout)
                Text(e.basis).font(.caption).foregroundStyle(.secondary)
                if !e.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(e.notes, id: \.self) { Label($0, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
                    }
                }
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
    /// One run, or every completed run of an experiment pooled together.
    enum Source: Hashable {
        case run(String)
        case pooled(experimentId: String)
    }

    @Environment(AppModel.self) private var model
    let source: Source
    @State private var comparison: RunComparison?
    @State private var comparingTrials = false

    init(runId: String) { source = .run(runId) }
    init(source: Source) { self.source = source }

    var body: some View {
        ScrollView {
            if let c = comparison {
                VStack(alignment: .leading, spacing: 18) {
                    header(c)
                    if c.run.status == .running, c.pooledRunIds == nil {
                        ProgressView(value: Double(c.run.trialsDone), total: Double(max(c.run.trialsTotal, 1))) {
                            Text("\(c.run.trialsDone) of \(Fmt.plural(c.run.trialsTotal, "trial")) done").font(.caption)
                        }
                    }
                    if !c.caveats.isEmpty { CaveatsBox(caveats: c.caveats) }
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Observed facts", systemImage: "checkmark.seal").font(.headline)
                        FactsTable(variants: c.variants)
                    }
                    if let diffs = c.differences, diffs.contains(where: { !$0.metrics.isEmpty }) {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Differences vs control", systemImage: "plusminus").font(.headline)
                            Text("Variant minus control with a 95% interval, one metric at a time. Highlighted intervals exclude zero, which a chance difference rarely does, but with many metrics a few can. An association, not proof of cause.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            ForEach(diffs, id: \.variantKey) { DifferencesTable(difference: $0) }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Heuristic signals", systemImage: "wand.and.stars").font(.headline)
                        Text("Pattern-matched interpretations, not facts. Bars show the share of trials; whiskers the 95% interval.")
                            .font(.caption).foregroundStyle(.secondary)
                        HeuristicsCharts(variants: c.variants)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label("Trials", systemImage: "list.number").font(.headline)
                            Spacer()
                            Button("Compare two trials…") { comparingTrials = true }
                                .controlSize(.small)
                                .disabled(c.trials.filter { $0.facts != nil }.count < 2)
                        }
                        ForEach(c.trials) { t in TrialRow(trial: t) }
                    }
                }
                .padding(20)
                .sheet(isPresented: $comparingTrials) { TrialCompareSheet(trials: c.trials.filter { $0.facts != nil }) }
            } else {
                ProgressView().padding()
            }
        }
        .task(id: model.eventTick) {
            comparison = await model.perform { client in
                switch source {
                case .run(let id): try await client.comparison(id)
                case .pooled(let exp): try await client.pooledComparison(experimentId: exp)
                }
            }
        }
    }

    func header(_ c: RunComparison) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    if let pooled = c.pooledRunIds {
                        Text("All runs · \(Fmt.plural(pooled.count, "run")) pooled").font(.title2.bold())
                    } else {
                        Text("Run · \(Fmt.runTitle(c.run.createdAt))").font(.title2.bold())
                        RunStatusIcon(status: c.run.status)
                    }
                }
                let duration = c.pooledRunIds == nil ? c.run.startedAt.flatMap { s in (c.run.finishedAt ?? Date()).timeIntervalSince(s) } : nil
                Text([Fmt.plural(c.trials.count, "trial"), duration.map { Fmt.duration($0 * 1000) }, c.pooledRunIds == nil ? "seed \(String(c.run.seed))" : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if case .run(let runId) = source, c.run.status == .running {
                Button("Cancel run", role: .destructive) { Task { _ = await model.perform { try await $0.cancelRun(runId) } } }
            }
            Menu {
                Button("Markdown report…") { Task { await export("md") } }
                Button("JSON bundle…") { Task { await export("json") } }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .fixedSize()
        }
    }

    func export(_ format: String) async {
        let (text, name): (String?, String)
        switch source {
        case .run(let id): (text, name) = (await model.perform { try await $0.report(id, format: format) }, id)
        case .pooled(let exp): (text, name) = (await model.perform { try await $0.pooledReport(experimentId: exp, format: format) }, "\(exp)-pooled")
        }
        guard let text else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "diorama-\(name).\(format)"
        panel.allowedContentTypes = [format == "md" ? UTType(filenameExtension: "md") ?? .plainText : .json]
        if panel.runModal() == .OK, let url = panel.url {
            do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { model.report(error) }
        }
    }
}

/// One steered variant against the control, metric by metric.
struct DifferencesTable: View {
    let difference: VariantDifference

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(difference.variantKey) vs \(difference.controlKey)").font(.callout.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    ForEach(["Metric", "Control", "Variant", "Difference", "95% interval"], id: \.self) { Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                }
                Divider()
                ForEach(difference.metrics, id: \.metric) { m in
                    GridRow {
                        HStack(spacing: 4) {
                            Text(m.label)
                            if m.isHeuristic { Badge(text: "heuristic", color: .secondary) }
                        }
                        Text(value(m, m.control))
                        Text(value(m, m.variant))
                        Text(delta(m, m.estimate)).fontWeight(m.excludesZero ? .semibold : .regular)
                        IntervalBar(metric: m)
                    }
                    .font(.callout.monospacedDigit())
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    func value(_ m: MetricDifference, _ v: Double) -> String {
        if m.kind == .proportion { return "\(Int((v * 100).rounded()))%" }
        if m.metric == "claudeCostUSD" { return Fmt.money(v) }
        if m.metric == "durationMs" { return Fmt.duration(v) }
        return abs(v) >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v)
    }

    func delta(_ m: MetricDifference, _ v: Double) -> String {
        if m.kind == .proportion { return String(format: "%+.0f pp", v * 100) }
        if m.metric == "claudeCostUSD" { return (v < 0 ? "−" : "+") + Fmt.money(abs(v)) }
        if m.metric == "durationMs" { return (v < 0 ? "−" : "+") + Fmt.duration(abs(v)) }
        return String(format: abs(v) >= 100 ? "%+.0f" : "%+.1f", v)
    }
}

/// The interval as text plus a small bar around zero, highlighted when it excludes zero.
struct IntervalBar: View {
    let metric: MetricDifference

    var body: some View {
        let lo = metric.interval95.low, hi = metric.interval95.high
        let span = max(abs(lo), abs(hi), metric.kind == .proportion ? 0.05 : 1e-9)
        HStack(spacing: 8) {
            GeometryReader { geo in
                let w = geo.size.width, mid = w / 2
                let x0 = mid + CGFloat(lo / span) * mid, x1 = mid + CGFloat(hi / span) * mid
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 1, height: 12).offset(x: mid)
                    Capsule().fill(metric.excludesZero ? Color.purple.opacity(0.8) : Color.secondary.opacity(0.45))
                        .frame(width: max(x1 - x0, 3), height: 5).offset(x: x0)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(width: 90, height: 14)
            Text(text).font(.caption.monospacedDigit()).foregroundStyle(metric.excludesZero ? .primary : .secondary)
        }
        .help(metric.excludesZero ? "The interval excludes zero" : "The interval includes zero: no clear difference")
    }

    var text: String {
        let lo = metric.interval95.low, hi = metric.interval95.high
        if metric.kind == .proportion { return String(format: "%+.0f to %+.0f pp", lo * 100, hi * 100) }
        func signed(_ v: Double, _ f: (Double) -> String) -> String { (v < 0 ? "−" : "+") + f(abs(v)) }
        if metric.metric == "durationMs" { return signed(lo) { Fmt.duration($0) } + " to " + signed(hi) { Fmt.duration($0) } }
        if metric.metric == "claudeCostUSD" { return signed(lo) { Fmt.money($0) } + " to " + signed(hi) { Fmt.money($0) } }
        return String(format: abs(hi) >= 100 || abs(lo) >= 100 ? "%+.0f to %+.0f" : "%+.2f to %+.2f", lo, hi)
    }
}

/// Two trials side by side: final answers (diffed), counts and tool calls.
struct TrialCompareSheet: View {
    @Environment(\.dismiss) private var dismiss
    let trials: [TrialInfo]
    @State private var a: String
    @State private var b: String

    init(trials: [TrialInfo]) {
        self.trials = trials
        // Default: the first control trial against the first steered one.
        let control = trials.first { $0.variantKey == "control" } ?? trials.first
        let other = trials.first { $0.variantKey != control?.variantKey } ?? trials.dropFirst().first
        _a = State(initialValue: control?.id ?? "")
        _b = State(initialValue: other?.id ?? "")
    }

    func trial(_ id: String) -> TrialInfo? { trials.first { $0.id == id } }
    func label(_ t: TrialInfo) -> String { "#\(t.order + 1) \(t.variantKey)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Compare two trials").font(.title2.bold())
            HStack {
                Picker("A", selection: $a) { ForEach(trials) { Text(label($0)).tag($0.id) } }.frame(maxWidth: 260)
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(.secondary)
                Picker("B", selection: $b) { ForEach(trials) { Text(label($0)).tag($0.id) } }.frame(maxWidth: 260)
            }
            if let ta = trial(a), let tb = trial(b), let fa = ta.facts, let fb = tb.facts {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow { Text(""); Text(label(ta)).font(.caption.bold()); Text(label(tb)).font(.caption.bold()) }
                    GridRow { Text("Turns").foregroundStyle(.secondary); Text("\(fa.numTurns ?? 0)"); Text("\(fb.numTurns ?? 0)") }
                    GridRow { Text("Duration").foregroundStyle(.secondary); Text(Fmt.duration(fa.durationMs)); Text(Fmt.duration(fb.durationMs)) }
                    GridRow { Text("Claude Code cost").foregroundStyle(.secondary); Text(Fmt.money(fa.claudeCostUSD)); Text(Fmt.money(fb.claudeCostUSD)) }
                    GridRow { Text("Rewrites").foregroundStyle(.secondary); Text("\(fa.rewritesApplied)"); Text("\(fb.rewritesApplied)") }
                    GridRow { Text("Tool calls").foregroundStyle(.secondary); Text(tools(fa.toolCalls)); Text(tools(fb.toolCalls)) }
                    GridRow { Text("Judge").foregroundStyle(.secondary); Text(ta.signals?.judgeVerdict ?? "—"); Text(tb.signals?.judgeVerdict ?? "—") }
                }
                .font(.callout)
                Text("Final answers (A → B)").font(.headline)
                ScrollView {
                    DiffText(original: fa.finalOutput, replacement: fb.finalOutput)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Text("Pick two finished trials.").foregroundStyle(.secondary)
            }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 760, height: 640)
    }

    func tools(_ calls: [String: Int]) -> String {
        calls.isEmpty ? "none" : calls.sorted { $0.key < $1.key }.map { "\(Fmt.toolName($0.key)) ×\($0.value)" }.joined(separator: ", ")
    }
}

struct CaveatsBox: View {
    let caveats: [String]
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Read these before drawing conclusions").font(.callout.weight(.semibold))
                ForEach(caveats, id: \.self) { Text($0).font(.callout).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.35)))
    }
}

struct FactsTable: View {
    let variants: [VariantComparison]
    let columns = ["Variant", "Valid", "Errors", "Turns", "Duration", "Claude Code", "Rewrites", "Rewrite cost", "Distinct outputs"]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
            GridRow {
                ForEach(columns, id: \.self) { Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
            }
            Divider()
            ForEach(variants, id: \.variantKey) { v in
                GridRow {
                    VariantLabel(key: v.variantKey, isControl: v.isControl)
                    Text("\(v.validTrials)/\(v.trials)")
                    Text("\(v.errorRate.count)").foregroundStyle(v.errorRate.count > 0 ? .red : .primary)
                    Text(Fmt.stat(v.turns))
                    Text(v.durationMs.n == 0 ? "—" : Fmt.duration(v.durationMs.mean))
                    Text(Fmt.stat(v.claudeCostUSD, money: true))
                    Text(Fmt.stat(v.rewritesApplied))
                    Text(Fmt.stat(v.rewriteCostUSD, money: true))
                    Text("\(v.distinctFinalOutputs)")
                }
                .font(.callout.monospacedDigit())
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct VariantLabel: View {
    let key: String
    let isControl: Bool
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(isControl ? Color.green : Color.purple).frame(width: 7, height: 7)
            Text(key).fontWeight(.semibold)
        }
    }
}

struct HeuristicsCharts: View {
    let variants: [VariantComparison]

    struct Point: Identifiable {
        var variant: String
        var isControl: Bool
        var stat: ProportionStat
        var id: String { variant }
    }

    var metrics: [(String, String, [Point])] {
        var out: [(String, String, [Point])] = [
            ("Echoed rewritten content", "The final answer repeats words the rewrite introduced.", variants.map { Point(variant: $0.variantKey, isControl: $0.isControl, stat: $0.echoedRewrittenContent) }),
            ("Flagged suspicion", "Claude said the content looked wrong, odd or contradictory.", variants.map { Point(variant: $0.variantKey, isControl: $0.isControl, stat: $0.flaggedSuspicion) }),
            ("Tried to verify", "Claude fetched or searched again to double-check.", variants.map { Point(variant: $0.variantKey, isControl: $0.isControl, stat: $0.attemptedVerification) }),
        ]
        if variants.contains(where: { $0.judgeAdopted != nil }) {
            out.append(("LLM judge: adopted", "A judge model rated the answer as having adopted the change.",
                        variants.compactMap { v in v.judgeAdopted.map { Point(variant: v.variantKey, isControl: v.isControl, stat: $0) } }))
        }
        return out
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
            ForEach(metrics, id: \.0) { title, help, points in
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.callout.weight(.semibold))
                    Text(help).font(.caption).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
                    VStack(spacing: 8) {
                        ForEach(points) { p in ProportionBar(point: p) }
                    }
                }
                .padding(12)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

/// One variant's share of trials, with its 95% interval as a whisker.
struct ProportionBar: View {
    let point: HeuristicsCharts.Point

    var body: some View {
        let st = point.stat
        HStack(spacing: 10) {
            Text(point.variant).font(.caption.weight(.medium)).frame(width: 70, alignment: .leading).lineLimit(1)
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    if st.total > 0 {
                        Capsule().fill(point.isControl ? Color.green.opacity(0.75) : Color.purple.opacity(0.8))
                            .frame(width: max(st.rate * w, st.rate > 0 ? 6 : 0))
                        Rectangle().fill(Color.primary.opacity(0.5))
                            .frame(width: max((st.interval95.high - st.interval95.low) * w, 1), height: 1.5)
                            .offset(x: st.interval95.low * w)
                        ForEach([st.interval95.low, st.interval95.high], id: \.self) { x in
                            Rectangle().fill(Color.primary.opacity(0.5)).frame(width: 1.5, height: 8).offset(x: min(x * w, w - 1.5))
                        }
                    }
                }
                .frame(height: 10)
                .frame(maxHeight: .infinity)
            }
            .frame(height: 14)
            Text(st.total > 0 ? "\(Fmt.proportion(st))  \(Int((st.rate * 100).rounded()))%" : "—")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
        }
        .help(st.total > 0 ? "\(Fmt.proportion(st)) trials · 95% interval \(Int((st.interval95.low * 100).rounded()))–\(Int((st.interval95.high * 100).rounded()))%" : "No valid trials")
    }
}

struct TrialRow: View {
    @Environment(AppModel.self) private var model
    let trial: TrialInfo
    @State private var expanded = false

    var statusColor: Color {
        switch trial.status {
        case .succeeded: .green
        case .running, .pending: .blue
        case .cancelled: .secondary
        case .failed, .invalid: .red
        }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                if let f = trial.facts {
                    Text("Final output").font(.caption.bold())
                    MonoBlock(text: f.finalOutput).frame(minHeight: 60, maxHeight: 200)
                    if !f.toolCalls.isEmpty {
                        Text("Tools used: " + f.toolCalls.sorted { $0.key < $1.key }.map { "\(Fmt.toolName($0.key)) ×\($0.value)" }.joined(separator: ", ")).font(.caption)
                    }
                    if !f.filesChanged.isEmpty { Text("Files changed: " + f.filesChanged.joined(separator: ", ")).font(.caption) }
                }
                if let s = trial.signals {
                    if let verdict = s.judgeVerdict {
                        Label {
                            Text("Judge: ").bold() + Text(verdict) + Text(s.judgeRationale.map { " — \($0)" } ?? "").foregroundStyle(.secondary)
                        } icon: { Image(systemName: "scale.3d") }
                        .font(.caption)
                    }
                    if !s.evidence.isEmpty {
                        Text("Heuristic evidence").font(.caption.bold())
                        ForEach(s.evidence, id: \.self) { Text("• " + $0).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if let m = trial.manifest {
                    Text("Claude Code \(m.claudeVersion ?? "?") · \(m.arguments.joined(separator: " "))").font(.caption2.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled).lineLimit(3)
                }
                if trial.sessionId != nil { Text("Full timeline: Sessions → Trials").font(.caption2).foregroundStyle(.secondary) }
            }
            .padding(.leading, 4)
        } label: {
            HStack(spacing: 8) {
                Text("#\(trial.order + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 28, alignment: .trailing)
                Circle().fill(statusColor).frame(width: 7, height: 7).help(trial.status.rawValue)
                Text(trial.variantKey).fontWeight(.medium)
                if let f = trial.facts {
                    Text("\(Fmt.plural(f.numTurns ?? 0, "turn")) · \(Fmt.money(f.claudeCostUSD)) · \(Fmt.plural(f.rewritesApplied, "rewrite"))").font(.caption).foregroundStyle(.secondary)
                }
                if let v = trial.signals?.judgeVerdict { Badge(text: v, color: v == "adopted" ? .purple : .secondary) }
                if let e = trial.error { Text(e).font(.caption).foregroundStyle(.red).lineLimit(1) }
                Spacer()
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
    /// What was inferred when the form was prefilled from a session.
    let notes: [String]

    init(draft: ExperimentDraft? = nil, created: @escaping (String) -> Void) {
        self.created = created
        notes = draft?.notes ?? []
        guard let d = draft?.definition else { return }
        _name = State(initialValue: d.name)
        _task = State(initialValue: d.task)
        _project = State(initialValue: d.projectPath)
        _claudeModel = State(initialValue: d.claude.model ?? "")
        _allowedTools = State(initialValue: d.claude.allowedTools.joined(separator: ","))
        _maxTurns = State(initialValue: d.claude.maxTurns ?? 15)
        _budget = State(initialValue: d.claude.maxBudgetUSD ?? 2)
        _trials = State(initialValue: d.trialsPerVariant)
        _concurrency = State(initialValue: d.concurrency)
        _frozen = State(initialValue: d.treatment == .frozen)
        _isolate = State(initialValue: d.claude.isolateConfiguration)
        _useJudge = State(initialValue: d.judge != nil)
        _variants = State(initialValue: d.variants)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(notes.isEmpty ? "New experiment" : "New experiment from a session").font(.title2.bold())
                Text("Runs the same task repeatedly in fresh copies of a project — unmodified and steered — and compares what Claude Code did.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !notes.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(notes, id: \.self) { Label($0, systemImage: "info.circle").font(.caption).fixedSize(horizontal: false, vertical: true) }
                    }
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 6)
                }
            }
            .padding([.horizontal, .top], 20)
            Form {
                Section {
                    TextField("Name", text: $name)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Task given to Claude Code")
                        TextEditor(text: $task).font(.body).frame(height: 60).scrollContentBackground(.hidden)
                            .padding(4).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    }
                    LabeledContent("Project folder") {
                        HStack {
                            TextField("Project folder", text: $project).labelsHidden()
                            Button("Choose…") { if let f = chooseFolder() { project = f } }
                        }
                    }
                } footer: {
                    Text("The folder is cloned (APFS copy-on-write) for every trial; the original is never modified.").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    ForEach($variants, id: \.key) { $v in
                        HStack(alignment: .center, spacing: 8) {
                            Circle().fill(v.profile == nil && v.prompt == nil ? Color.green : Color.purple).frame(width: 7, height: 7)
                            TextField("Key", text: $v.key).labelsHidden().frame(width: 90)
                            Picker("Profile", selection: Binding(get: { v.profile ?? "" }, set: { v.profile = $0.isEmpty ? nil : $0 })) {
                                Text("No profile").tag("")
                                ForEach(model.profiles) { Text($0.name).tag($0.name) }
                                // A version pinned by "Experiment from session" (pv_…).
                                if let p = v.profile, p.hasPrefix("pv_") { Text("\(v.name) (pinned)").tag(p) }
                            }
                            .labelsHidden().frame(width: 160)
                            TextField("Session prompt", text: Binding(
                                get: { v.prompt?.text ?? "" },
                                set: { v.prompt = $0.isEmpty ? nil : SessionPrompt(text: $0, tools: allowedTools.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }),
                                prompt: Text("Session prompt (blank = none)"))
                            .labelsHidden()
                            if variants.count > 2 {
                                Button { variants.removeAll { $0.key == v.key } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                            }
                        }
                    }
                    Button("Add variant") { variants.append(ExperimentVariant(key: "v\(variants.count + 1)", name: "Variant \(variants.count + 1)")) }
                } header: {
                    Text("Variants")
                } footer: {
                    Text("A variant with no profile and no prompt is the unmodified control (green). One is required.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Claude Code") {
                    TextField("Model", text: $claudeModel, prompt: Text("Default"))
                    TextField("Allowed tools", text: $allowedTools)
                    Stepper("Max turns: \(maxTurns)", value: $maxTurns, in: 1...200)
                    Stepper("Max budget per trial: \(Fmt.money(budget))", value: $budget, in: 0.1...50, step: 0.5)
                    Toggle("Isolate configuration (no user settings or MCP servers)", isOn: $isolate)
                }
                Section("Trials") {
                    Stepper("Trials per variant: \(trials)", value: $trials, in: 1...200)
                    Stepper("Run \(concurrency) at a time", value: $concurrency, in: 1...8)
                    Toggle("Frozen treatment (reuse identical rewrites across trials)", isOn: $frozen)
                    Toggle("LLM judge after the run (uses your API key)", isOn: $useJudge)
                }
            }
            .formStyle(.grouped)
            HStack {
                Text("You'll see a cost estimate before anything runs.").font(.caption).foregroundStyle(.secondary)
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
                .buttonStyle(.borderedProminent)
                .disabled(task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(20)
        }
        .frame(width: 700, height: 760)
    }
}
