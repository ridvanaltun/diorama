import DioramaCore
import SwiftUI

struct SessionsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: String?
    @State private var showNew = false
    @State private var kindFilter: SessionKind? = .interactive

    var filtered: [SessionInfo] { model.sessions.filter { kindFilter == nil || $0.kind == kindFilter } }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                Picker("", selection: $kindFilter) {
                    Text("Interactive").tag(SessionKind?.some(.interactive))
                    Text("Trials").tag(SessionKind?.some(.trial))
                    Text("All").tag(SessionKind?.none)
                }
                .pickerStyle(.segmented).labelsHidden().padding(8)
                List(filtered, selection: $selection) { s in
                    SessionRow(session: s).tag(s.id)
                }
                .overlay {
                    if filtered.isEmpty {
                        ContentUnavailableView("No sessions", systemImage: "terminal", description: Text("Start one with New Session, or run `diorama run` in a project folder."))
                    }
                }
            }
            .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
            Group {
                if let id = selection {
                    TimelineView(sessionId: id).id(id)
                } else {
                    ContentUnavailableView("Select a session", systemImage: "list.bullet.rectangle", description: Text("The timeline shows every request, tool result, rewrite and what Claude did next."))
                }
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItem {
                Button { showNew = true } label: { Label("New Session", systemImage: "plus") }
            }
            ToolbarItem {
                Button { Task { await model.refreshSessions() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
        }
        .sheet(isPresented: $showNew) { NewSessionSheet() }
        .navigationTitle("Sessions")
        .task(id: model.sessions.count) {
            if model.snapshotDir != nil, selection == nil {
                selection = (filtered.first { $0.stats.rewrites > 0 } ?? filtered.first)?.id
            }
        }
    }
}

struct SessionRow: View {
    let session: SessionInfo
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(session.name).font(.headline).lineLimit(1)
                Spacer()
                if session.status == .active { Badge(text: "active", color: .green) }
            }
            Text(session.profileName.map { "\($0) v\(session.profileVersionNumber ?? 0)" } ?? (session.prompt != nil ? "session prompt" : "no rules"))
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text("\(session.stats.exchanges) req")
                Text("\(session.stats.rewrites) rewritten").foregroundStyle(session.stats.rewrites > 0 ? .purple : .secondary)
                if session.stats.failures > 0 { Text("\(session.stats.failures) failed").foregroundStyle(.red) }
                if session.stats.anomalies > 0 { Text("\(session.stats.anomalies) anomalies").foregroundStyle(.orange) }
            }
            .font(.caption2).foregroundStyle(.secondary)
            Text(session.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Timeline

struct TimelineView: View {
    @Environment(AppModel.self) private var model
    let sessionId: String
    @State private var timeline: Timeline?
    @State private var selectedDecision: String?
    @State private var showReplays = false

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                if let t = timeline {
                    SessionHeader(session: t.session)
                    Divider()
                    Toggle("Show replayed results", isOn: $showReplays).toggleStyle(.checkbox).font(.caption).padding(.horizontal, 12).padding(.vertical, 6)
                    List(selection: $selectedDecision) {
                        let anomalies = t.events.filter { $0.kind == .anomaly || $0.kind == .rewriteFailed || $0.kind == .warning }
                        if !anomalies.isEmpty {
                            Section("Events") {
                                ForEach(anomalies) { ev in
                                    Label(ev.message, systemImage: ev.kind == .anomaly ? "exclamationmark.triangle" : "xmark.octagon")
                                        .foregroundStyle(ev.kind == .anomaly ? .orange : .red).font(.caption)
                                }
                            }
                        }
                        ForEach(t.exchanges) { e in
                            ExchangeRow(exchange: e, decisions: t.decisions, showReplays: showReplays)
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            if let d = selectedDecision {
                DecisionDetailView(toolUseId: d).id(d).frame(minWidth: 380, idealWidth: 480)
            }
        }
        .task(id: model.eventTick) {
            if model.lastEvent?.sessionId == nil || model.lastEvent?.sessionId == sessionId || timeline == nil {
                timeline = await model.perform { try await $0.timeline(sessionId) }
                if model.snapshotDir != nil, selectedDecision == nil {
                    selectedDecision = timeline?.decisions.first { $0.outcome == .rewritten }?.toolUseId
                }
            }
        }
    }
}

struct SessionHeader: View {
    let session: SessionInfo
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.name).font(.title2.bold())
                Badge(text: session.status.rawValue, color: session.status == .active ? .green : .secondary)
                if session.kind == .trial { Badge(text: "trial", color: .blue) }
                Spacer()
                Text(session.id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text((session.cwd as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 14) {
                Label(session.profileName.map { "\($0) v\(session.profileVersionNumber ?? 0)" } ?? "No profile", systemImage: "slider.horizontal.3")
                if let p = session.prompt { Label("Prompt: \(p.text)", systemImage: "text.quote").lineLimit(1) }
                if session.lockdown != .none { Label("Lockdown: \(session.lockdown.rawValue)", systemImage: "lock") }
            }
            .font(.caption)
            HStack(spacing: 14) {
                Text("\(session.stats.exchanges) requests")
                Text("\(session.stats.toolResults) tool results")
                Text("\(session.stats.rewrites) rewritten").foregroundStyle(.purple)
                Text("\(session.stats.failures) failed").foregroundStyle(session.stats.failures > 0 ? .red : .secondary)
                Text("rewrite cost \(formatMoney(session.stats.rewriteCostUSD))")
            }
            .font(.caption).foregroundStyle(.secondary)
            if !session.flags.isEmpty {
                Text("Flags: " + session.flags.joined(separator: ", ")).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(12)
    }
}

struct ExchangeRow: View {
    let exchange: ExchangeSummary
    let decisions: [DecisionSummary]
    let showReplays: Bool

    var body: some View {
        let e = exchange
        let shown = e.toolResults.filter { showReplays || $0.handling.isNewDecision }
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("#\(e.id)").font(.caption.monospaced()).foregroundStyle(.secondary)
                Text(e.path).font(.caption.monospaced())
                if let rc = e.requestClass { Badge(text: rc, color: rc == "main" ? .blue : .gray) }
                Spacer()
                Text(e.status.map(String.init) ?? "…").font(.caption.monospaced()).foregroundStyle((e.status ?? 200) >= 400 ? .red : .secondary)
                Text(formatMs(e.durationMs)).font(.caption).foregroundStyle(.secondary)
            }
            if let u = e.usage {
                Text("in \(u.inputTokens) · out \(u.outputTokens) · cache read \(u.cacheReadTokens) / write \(u.cacheWriteTokens) · +\(formatMs(e.addedLatencyMs)) added")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            ForEach(shown, id: \.toolUseId) { tr in
                let d = decisions.first { $0.toolUseId == tr.toolUseId }
                HStack(spacing: 6) {
                    Badge(text: tr.handling.label, color: tr.handling.color)
                    Text(tr.toolName ?? "tool").font(.caption.bold())
                    Text(d?.reason ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .tag(tr.toolUseId)
                .contentShape(Rectangle())
            }
            if let a = e.assistant {
                if !a.text.isEmpty {
                    Text("Claude: " + a.text).font(.caption).lineLimit(3).foregroundStyle(.primary.opacity(0.85))
                }
                ForEach(a.toolUses, id: \.id) { u in
                    Text("→ calls \(u.name) \(u.input)").font(.caption.monospaced()).lineLimit(1).foregroundStyle(.secondary)
                }
            }
            if let err = e.error { Text(err).font(.caption).foregroundStyle(.red) }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Decision detail

struct DecisionDetailView: View {
    @Environment(AppModel.self) private var model
    let toolUseId: String
    @State private var detail: DecisionDetail?
    @State private var mode = 0

    var body: some View {
        ScrollView {
            if let d = detail {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(d.summary.toolName ?? "Tool result").font(.title3.bold())
                        Badge(text: d.summary.outcome.rawValue, color: d.summary.outcome.color)
                        Spacer()
                        Text("replayed \(d.summary.replayCount)×").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(d.summary.toolUseId).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    LabeledContent("Reason") { Text(d.summary.reason).textSelection(.enabled) }
                    if let i = d.toolInput { LabeledContent("Tool input") { Text(i).font(.caption.monospaced()).textSelection(.enabled) } }
                    if !d.summary.rules.isEmpty {
                        GroupBox("Applied rules") {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(d.summary.rules, id: \.ruleId) { r in
                                    Text("\(r.name) · \(r.ruleHash)\(r.profileVersionId.map { " · \($0)" } ?? "")").font(.caption.monospaced())
                                }
                                ForEach(d.instructions, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if let r = d.replacementText {
                        Picker("", selection: $mode) {
                            Text("Diff").tag(0)
                            Text("Side by side").tag(1)
                        }.pickerStyle(.segmented).labelsHidden()
                        if mode == 0 {
                            GroupBox("Changes") { DiffText(original: d.originalText, replacement: r).padding(4) }
                        } else {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading) { Text("Original").font(.caption.bold()); MonoBlock(text: d.originalText).frame(minHeight: 200) }
                                VStack(alignment: .leading) { Text("Rewritten (what Claude saw)").font(.caption.bold()); MonoBlock(text: r).frame(minHeight: 200) }
                            }
                        }
                    } else {
                        Text("Content (forwarded unchanged)").font(.caption.bold())
                        MonoBlock(text: d.originalText).frame(minHeight: 160)
                    }
                    if !d.attempts.isEmpty {
                        GroupBox("Rewrite agent attempts") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(d.attempts) { a in
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack {
                                            Badge(text: a.status.rawValue, color: a.status == .succeeded ? .purple : (a.status == .unchanged ? .secondary : .red))
                                            Text("\(a.modelServed ?? a.modelRequested) · \(formatMs(a.latencyMs)) · \(formatMoney(a.costUSD)) · \(a.promptVersion)").font(.caption)
                                        }
                                        if let e = a.explanation { Text(e).font(.caption) }
                                        if let err = a.error { Text(err).font(.caption).foregroundStyle(.red) }
                                        ForEach(Array(a.edits.enumerated()), id: \.offset) { _, e in
                                            Text("“\(e.find)” → “\(e.replace)” — \(e.rationale)").font(.caption.monospaced()).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if let f = d.followUp {
                        GroupBox("What Claude did next") {
                            VStack(alignment: .leading, spacing: 4) {
                                if !f.text.isEmpty { Text(f.text).font(.callout).textSelection(.enabled) }
                                ForEach(f.toolUses, id: \.id) { u in Text("→ \(u.name) \(u.input)").font(.caption.monospaced()) }
                                if let s = f.stopReason { Text("stop: \(s)").font(.caption2).foregroundStyle(.secondary) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(14)
            } else {
                ProgressView().padding()
            }
        }
        .task(id: model.eventTick) { detail = await model.perform { try await $0.decision(toolUseId) } }
    }
}

// MARK: - New session

struct NewSessionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var folder = FileManager.default.homeDirectoryForCurrentUser.path
    @State private var name = ""
    @State private var profile = ""
    @State private var prompt = ""
    @State private var promptTools = SessionPrompt.defaultTools.joined(separator: ",")
    @State private var taskContext = false
    @State private var pageStage = false
    @State private var lockdown = LockdownPreset.none
    @State private var claudeArgs = ""

    var command: String {
        var parts = ["cd", shellQuote(folder), "&&", shellQuote(model.cliPath), "run"]
        if !name.isEmpty { parts += ["--name", shellQuote(name)] }
        if !profile.isEmpty { parts += ["--profile", shellQuote(profile)] }
        if !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts += ["--prompt", shellQuote(prompt), "--prompt-tools", shellQuote(promptTools)]
            if taskContext { parts += ["--prompt-context", "task"] }
            if pageStage { parts += ["--prompt-stage", "page"] }
        }
        if lockdown != .none { parts += ["--lockdown", lockdown.rawValue] }
        if !claudeArgs.isEmpty { parts += ["--", claudeArgs] }
        return parts.joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New routed session").font(.title2.bold())
            Text("Starts Claude Code in Terminal through Diorama. Only this session is routed; your other Claude Code sessions and settings are untouched.")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                HStack {
                    TextField("Project folder", text: $folder)
                    Button("Choose…") { if let f = chooseFolder() { folder = f } }
                }
                TextField("Session name (optional)", text: $name)
                Picker("Profile", selection: $profile) {
                    Text("None").tag("")
                    ForEach(model.profiles) { p in Text("\(p.name) (v\(p.currentVersionNumber))").tag(p.name) }
                }
                VStack(alignment: .leading) {
                    Text("Session prompt (optional)")
                    TextEditor(text: $prompt).font(.body).frame(height: 90).overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                }
                TextField("Prompt applies to tools", text: $promptTools).disabled(pageStage)
                Toggle("Rewrite WebFetch pages before summarization (pre-extraction)", isOn: $pageStage)
                Toggle("Give the rewrite agent the session's task (opt-in context)", isOn: $taskContext)
                Picker("Lockdown", selection: $lockdown) {
                    Text("None").tag(LockdownPreset.none)
                    Text("Block shell network tools").tag(LockdownPreset.network)
                }
                TextField("Extra Claude Code arguments (optional)", text: $claudeArgs)
            }
            if model.keyStatus?.configured == false, !profile.isEmpty || !prompt.isEmpty {
                Label("No rewrite API key is configured; matching results will pass through unchanged. Add one in Settings.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
            }
            GroupBox("Command") { Text(command).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Copy Command") { copyToPasteboard(command) }
                Button("Open in Terminal") {
                    do {
                        try openInTerminal(command)
                        dismiss()
                    } catch { model.report(error) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
    }
}
