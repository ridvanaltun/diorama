import AppKit
import DioramaCore
import SwiftUI

struct SessionsView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: String?
    @State private var showNew = false
    @State private var kindFilter: SessionKind? = .interactive

    var filtered: [SessionInfo] { model.sessions.filter { kindFilter == nil || $0.kind == kindFilter } }

    var body: some View {
        Group {
            if model.sessions.isEmpty {
                GettingStartedView(onNewSession: { showNew = true })
            } else {
                HSplitView {
                    VStack(spacing: 0) {
                        Picker("Show", selection: $kindFilter) {
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
                                ContentUnavailableView("Nothing here", systemImage: "line.3.horizontal.decrease.circle", description: Text("No sessions of this kind yet."))
                            }
                        }
                    }
                    .frame(minWidth: 240, idealWidth: 270, maxWidth: 340)
                    Group {
                        if let id = selection {
                            TimelineView(sessionId: id).id(id)
                        } else {
                            ContentUnavailableView("Select a session", systemImage: "list.bullet.rectangle",
                                                   description: Text("See every tool result Claude received, what Diorama changed, and what Claude did next."))
                        }
                    }
                    .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button { showNew = true } label: { Label("New Session", systemImage: "plus") }
                    .help("Start Claude Code in Terminal, routed through Diorama")
            }
            ToolbarItem {
                Button { Task { await model.refreshSessions() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
        }
        .sheet(isPresented: $showNew) { NewSessionSheet() }
        .navigationTitle("Sessions")
        .onChange(of: model.wantsNewSession, initial: true) { _, wants in
            if wants {
                showNew = true
                model.wantsNewSession = false
            }
        }
        .onChange(of: model.focusSessionId, initial: true) { _, id in
            guard let id else { return }
            if let s = model.sessions.first(where: { $0.id == id }), kindFilter != nil { kindFilter = s.kind }
            selection = id
            model.focusSessionId = nil
        }
        .task(id: model.sessions.count) {
            if selection == nil, let first = filtered.first(where: { $0.stats.rewrites > 0 }) ?? filtered.first, model.snapshotDir != nil || filtered.count == 1 {
                selection = first.id
            }
        }
    }
}

// MARK: - Getting started

struct GettingStartedView: View {
    @Environment(AppModel.self) private var model
    let onNewSession: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Welcome to Diorama").font(.largeTitle.bold())
                    Text("Stage what your coding agent sees. Measure what it does.").font(.title3).foregroundStyle(.secondary)
                }
                VStack(spacing: 12) {
                    StepCard(number: 1, done: model.keyStatus?.configured == true, title: "Add an API key for the rewrite agent",
                             detail: "Rewrites use your own Anthropic key, stored in the Keychain. Claude Code keeps its normal sign-in.",
                             action: ("Open Settings", { model.section = .settings }))
                    StepCard(number: 2, done: !model.profiles.isEmpty, title: "Create a profile",
                             detail: "A profile is a versioned set of rules: which tool results to change, and how.",
                             action: ("Choose a template", { model.section = .profiles; model.wantsNewProfile = true }))
                    StepCard(number: 3, done: false, title: "Start a routed session",
                             detail: "Opens Claude Code in Terminal through Diorama. Only that session is affected.",
                             action: ("New Session", onNewSession))
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Prefer the terminal?", systemImage: "terminal").font(.headline)
                        Text("Install the command-line tool, then run `diorama run` in any project folder:").font(.callout).foregroundStyle(.secondary)
                        CommandLineInstall()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
            }
            .padding(32)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

struct StepCard: View {
    let number: Int
    let done: Bool
    let title: String
    let detail: String
    let action: (String, () -> Void)

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(done ? Color.green.opacity(0.18) : Color.accentColor.opacity(0.14)).frame(width: 30, height: 30)
                if done {
                    Image(systemName: "checkmark").font(.callout.bold()).foregroundStyle(.green)
                } else {
                    Text("\(number)").font(.callout.bold()).foregroundStyle(Color.accentColor)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).strikethrough(done, color: .secondary).foregroundStyle(done ? .secondary : .primary)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(action.0, action: action.1).disabled(done)
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct CommandLineInstall: View {
    @Environment(AppModel.self) private var model
    var command: String { "sudo ln -sf \(FormLogic.shellQuote(model.cliPath)) /usr/local/bin/diorama" }

    var body: some View {
        HStack {
            Text(command).font(.caption.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Copy") { copyToPasteboard(command) }.controlSize(.small)
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Session list

struct SessionRow: View {
    let session: SessionInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(session.status == .active ? Color.green : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                    .help(session.status == .active ? "Running" : "Ended")
                Text(session.name).font(.headline).lineLimit(1)
                Spacer(minLength: 4)
                Text(Fmt.relative(session.createdAt)).font(.caption2).foregroundStyle(.tertiary)
            }
            Text(session.profileName.map { "\($0) · v\(session.profileVersionNumber ?? 0)" } ?? (session.prompt != nil ? "Session prompt" : "No rules (record only)"))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 6) {
                if session.stats.rewrites > 0 { Badge(text: Fmt.plural(session.stats.rewrites, "rewrite"), color: .purple) }
                if session.stats.failures > 0 { Badge(text: Fmt.plural(session.stats.failures, "failure"), color: .red) }
                if session.stats.anomalies > 0 { Badge(text: Fmt.plural(session.stats.anomalies, "anomaly", "anomalies"), color: .orange) }
                Text(Fmt.plural(session.stats.exchanges, "request")).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
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
                    let grouped = TimelineLogic.turns(t.exchanges)
                    let decisions = Dictionary(uniqueKeysWithValues: t.decisions.map { ($0.toolUseId, $0) })
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            let notices = t.events.filter { $0.kind == .anomaly || $0.kind == .rewriteFailed }
                            if !notices.isEmpty { NoticesCard(events: notices) }
                            if grouped.turns.isEmpty {
                                ContentUnavailableView("Waiting for Claude Code", systemImage: "hourglass",
                                                       description: Text("Requests appear here as soon as the session talks to the model."))
                                    .padding(.top, 40)
                            }
                            ForEach(grouped.turns) { turn in
                                TurnCard(turn: turn, decisions: decisions, showReplays: showReplays, selection: $selectedDecision)
                            }
                        }
                        .padding(12)
                    }
                    .safeAreaInset(edge: .bottom) {
                        HStack {
                            Toggle("Show replayed results", isOn: $showReplays).toggleStyle(.checkbox).font(.caption)
                                .help("Results already decided earlier are re-sent with every later request; Diorama replays the same bytes.")
                            Spacer()
                            Text(Fmt.plural(grouped.turns.count, "turn")).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.bar)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            if let d = selectedDecision {
                DecisionDetailView(toolUseId: d, onClose: { selectedDecision = nil }).id(d).frame(minWidth: 400, idealWidth: 480)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.name).font(.title2.bold()).lineLimit(1)
                Badge(text: session.status == .active ? "running" : "ended", color: session.status == .active ? .green : .secondary)
                if session.kind == .trial { Badge(text: "trial", color: .blue) }
                Spacer()
                CopyableID(id: session.id)
            }
            HStack(spacing: 12) {
                Label(Fmt.shortPath(session.cwd), systemImage: "folder").lineLimit(1).truncationMode(.middle)
                Label(session.profileName.map { "\($0) · v\(session.profileVersionNumber ?? 0)" } ?? "No profile", systemImage: "slider.horizontal.3")
                if session.lockdown != .none { Label("Network lockdown", systemImage: "lock") }
            }
            .font(.caption).foregroundStyle(.secondary)
            if let p = session.prompt {
                Label {
                    Text(p.text).lineLimit(2)
                } icon: {
                    Image(systemName: p.stage == .page ? "doc.richtext" : "text.quote")
                }
                .font(.caption).foregroundStyle(.secondary)
                .help(p.stage == .page ? "Session prompt (WebFetch pages, before summarization)" : "Session prompt for: \(p.tools.joined(separator: ", "))")
            }
            HStack(spacing: 8) {
                StatTile(value: "\(session.stats.exchanges)", label: "requests")
                StatTile(value: "\(session.stats.toolResults)", label: "tool results")
                StatTile(value: "\(session.stats.rewrites)", label: "rewritten", tint: session.stats.rewrites > 0 ? .purple : nil)
                StatTile(value: "\(session.stats.failures)", label: "failed", tint: session.stats.failures > 0 ? .red : nil)
                StatTile(value: Fmt.money(session.stats.rewriteCostUSD), label: "rewrite cost")
            }
            if !session.flags.isEmpty {
                Label(session.flags.joined(separator: ", "), systemImage: "flag").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(14)
    }
}

struct StatTile: View {
    let value: String
    let label: String
    var tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.headline.monospacedDigit()).foregroundStyle(tint ?? .primary)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(minWidth: 70, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct CopyableID: View {
    let id: String
    @State private var copied = false

    var body: some View {
        Button {
            copyToPasteboard(id)
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
        } label: {
            Label(copied ? "Copied" : id, systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Copy \(id)")
    }
}

struct NoticesCard: View {
    let events: [SessionEvent]
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(events) { ev in
                    Label(ev.message, systemImage: ev.kind == .anomaly ? "exclamationmark.triangle" : "xmark.octagon")
                        .font(.caption).foregroundStyle(ev.kind == .anomaly ? .orange : .red)
                }
            }
            .padding(.top, 4)
        } label: {
            Label(Fmt.plural(events.count, "notice") + " — rewrite failures or anomalies", systemImage: "exclamationmark.bubble")
                .font(.callout.weight(.medium)).foregroundStyle(.orange)
        }
        .padding(10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// One turn: the tool results Claude received in this request, then Claude's response.
struct TurnCard: View {
    let turn: TimelineLogic.Turn
    let decisions: [String: DecisionSummary]
    let showReplays: Bool
    @Binding var selection: String?
    @State private var showBackground = false

    var body: some View {
        let e = turn.exchange
        let results = turn.newResults(includeReplays: showReplays)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Turn \(turn.number)").font(.subheadline.bold())
                if e.requestClass == "subagent" { Badge(text: "subagent", color: .teal) }
                if let status = e.status, status >= 400 { Badge(text: "HTTP \(status)", color: .red) }
                Spacer()
                TurnMetrics(exchange: e)
            }
            if !results.isEmpty {
                VStack(spacing: 4) {
                    ForEach(results, id: \.toolUseId) { tr in
                        ToolResultRow(entry: tr, decision: decisions[tr.toolUseId], selected: selection == tr.toolUseId) {
                            selection = selection == tr.toolUseId ? nil : tr.toolUseId
                        }
                    }
                }
            }
            if let a = e.assistant {
                AssistantBlock(assistant: a)
            } else if e.status == nil {
                Label("Waiting for the response…", systemImage: "ellipsis").font(.caption).foregroundStyle(.secondary)
            }
            if let err = e.error { Label(err, systemImage: "exclamationmark.octagon").font(.caption).foregroundStyle(.red) }
            if !turn.background.isEmpty {
                DisclosureGroup(isExpanded: $showBackground) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(turn.background) { b in BackgroundRow(exchange: b, decisions: decisions, selection: $selection) }
                    }
                    .padding(.top, 4)
                } label: {
                    Text(Fmt.plural(turn.background.count, "background request")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct TurnMetrics: View {
    let exchange: ExchangeSummary
    var body: some View {
        HStack(spacing: 8) {
            if let u = exchange.usage {
                Text("\(Fmt.tokens(u.inputTokens + u.cacheReadTokens + u.cacheWriteTokens)) in · \(Fmt.tokens(u.outputTokens)) out")
                if let hit = TimelineLogic.cacheHitRate(u) { Text("cache \(Int((hit * 100).rounded()))%").help("Share of the prompt read from the prompt cache") }
            }
            if let added = exchange.addedLatencyMs, added >= 1 {
                Text("+\(Fmt.duration(added))").help("Time Diorama added before forwarding (includes rewrites)")
            }
            Text(Fmt.duration(exchange.durationMs))
        }
        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
    }
}

struct ToolResultRow: View {
    let entry: ToolResultEntry
    let decision: DecisionSummary?
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: Fmt.toolIcon(entry.toolName)).frame(width: 18).foregroundStyle(entry.handling.color == .secondary ? .secondary : entry.handling.color)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(Fmt.toolName(entry.toolName)).font(.callout.weight(.medium))
                        Badge(text: entry.handling.label, color: entry.handling.color)
                    }
                    if let reason = decision?.reason, entry.handling != .decidedUnchanged || !reason.hasPrefix("no rule") {
                        Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(selected ? Color.accentColor.opacity(0.15) : (hovering ? Color.primary.opacity(0.05) : .clear), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Show the audit record")
    }
}

struct AssistantBlock: View {
    let assistant: AssistantSummary
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !assistant.text.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkle").foregroundStyle(.orange).frame(width: 18)
                    Text(assistant.text).font(.callout).lineLimit(expanded ? nil : 4).textSelection(.enabled)
                        .onTapGesture { expanded.toggle() }
                }
            }
            ForEach(assistant.toolUses, id: \.id) { u in
                HStack(spacing: 8) {
                    Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary).frame(width: 18)
                    Text("Calls ").font(.callout).foregroundStyle(.secondary)
                        + Text(Fmt.toolName(u.name)).font(.callout.weight(.medium))
                        + Text(Fmt.toolTarget(u.name, u.input).map { "  \($0)" } ?? "").font(.callout).foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .help(u.input)
            }
        }
    }
}

struct BackgroundRow: View {
    let exchange: ExchangeSummary
    let decisions: [String: DecisionSummary]
    @Binding var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: "gearshape.2").foregroundStyle(.tertiary)
                Text(TimelineLogic.backgroundLabel(exchange)).font(.caption)
                Spacer()
                TurnMetrics(exchange: exchange)
            }
            ForEach(exchange.toolResults.filter { $0.handling.isNewDecision }, id: \.toolUseId) { tr in
                ToolResultRow(entry: tr, decision: decisions[tr.toolUseId], selected: selection == tr.toolUseId) {
                    selection = selection == tr.toolUseId ? nil : tr.toolUseId
                }
            }
        }
    }
}

// MARK: - Decision detail

struct DecisionDetailView: View {
    @Environment(AppModel.self) private var model
    let toolUseId: String
    var onClose: (() -> Void)?
    @State private var detail: DecisionDetail?
    @State private var mode = 0
    @State private var showTechnical = false

    var body: some View {
        ScrollView {
            if let d = detail {
                VStack(alignment: .leading, spacing: 16) {
                    header(d)
                    outcomeBanner(d)
                    if let r = d.replacementText {
                        section("What changed") {
                            Picker("View", selection: $mode) {
                                Text("Changes").tag(0)
                                Text("Side by side").tag(1)
                            }.pickerStyle(.segmented).labelsHidden().fixedSize()
                            if mode == 0 {
                                DiffText(original: d.originalText, replacement: r).padding(10)
                                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                            } else {
                                HStack(alignment: .top, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 4) { Text("Original").font(.caption.bold()).foregroundStyle(.secondary); MonoBlock(text: d.originalText).frame(minHeight: 200) }
                                    VStack(alignment: .leading, spacing: 4) { Text("What Claude saw").font(.caption.bold()).foregroundStyle(.secondary); MonoBlock(text: r).frame(minHeight: 200) }
                                }
                            }
                        }
                    } else {
                        section("Content (forwarded unchanged)") { MonoBlock(text: d.originalText).frame(minHeight: 140, maxHeight: 320) }
                    }
                    if let f = d.followUp, !(f.text.isEmpty && f.toolUses.isEmpty) {
                        section("What Claude did next") {
                            AssistantBlock(assistant: f)
                        }
                    }
                    if !d.summary.rules.isEmpty {
                        section("Rules that applied") {
                            ForEach(Array(zip(d.summary.rules, d.instructions + Array(repeating: "", count: max(0, d.summary.rules.count - d.instructions.count)))), id: \.0.ruleId) { rule, instruction in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(rule.name).font(.callout.weight(.medium))
                                    if !instruction.isEmpty {
                                        Text(instruction.replacingOccurrences(of: "[\(rule.name)] ", with: "")).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    if !d.attempts.isEmpty {
                        section("Rewrite agent") {
                            ForEach(d.attempts) { a in AttemptRow(attempt: a) }
                        }
                    }
                    DisclosureGroup("Technical details", isExpanded: $showTechnical) {
                        VStack(alignment: .leading, spacing: 6) {
                            LabeledContent("tool_use_id") { Text(d.summary.toolUseId).textSelection(.enabled) }
                            if let i = d.toolInput { LabeledContent("Tool input") { Text(i).textSelection(.enabled).lineLimit(6) } }
                            ForEach(d.summary.rules, id: \.ruleId) { r in
                                LabeledContent(r.name) { Text("rule \(r.ruleHash)\(r.profileVersionId.map { " · \($0)" } ?? "")").textSelection(.enabled) }
                            }
                            LabeledContent("Replayed") { Text("\(d.summary.replayCount)×") }
                        }
                        .font(.caption.monospaced())
                        .padding(.top, 4)
                    }
                    .font(.callout)
                }
                .padding(16)
            } else {
                ProgressView().padding()
            }
        }
        .task(id: model.eventTick) { detail = await model.perform { try await $0.decision(toolUseId) } }
    }

    func header(_ d: DecisionDetail) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: Fmt.toolIcon(d.summary.toolName)).font(.title2).foregroundStyle(d.summary.outcome.color == .secondary ? .secondary : d.summary.outcome.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(d.summary.toolUseId.hasPrefix("page:") ? "WebFetch page (before summarization)" : Fmt.toolName(d.summary.toolName)).font(.title3.bold())
                if let target = Fmt.toolTarget(d.summary.toolName, d.toolInput) {
                    Text(target).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            if let onClose {
                Button(action: onClose) { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain).help("Close")
            }
        }
    }

    func outcomeBanner(_ d: DecisionDetail) -> some View {
        let (icon, title): (String, String) = switch d.summary.outcome {
        case .rewritten: ("wand.and.stars", "Rewritten")
        case .failed: ("xmark.octagon", "Rewrite failed — original forwarded")
        case .unchanged: ("checkmark.circle", "Forwarded unchanged")
        }
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(d.summary.reason).font(.callout).textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(d.summary.outcome == .unchanged ? Color.primary : d.summary.outcome.color)
        .padding(10)
        .background((d.summary.outcome == .unchanged ? Color.secondary : d.summary.outcome.color).opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AttemptRow: View {
    let attempt: RewriteAttemptInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Badge(text: attempt.status.rawValue, color: attempt.status == .succeeded ? .purple : (attempt.status == .unchanged ? .secondary : .red))
                Text(attempt.modelServed ?? attempt.modelRequested).font(.caption.monospaced())
                Spacer()
                Text("\(Fmt.duration(attempt.latencyMs)) · \(Fmt.money(attempt.costUSD))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let e = attempt.explanation { Text(e).font(.callout) }
            if let err = attempt.error { Text(err).font(.caption).foregroundStyle(.red) }
            ForEach(Array(attempt.edits.enumerated()), id: \.offset) { _, edit in
                VStack(alignment: .leading, spacing: 1) {
                    (Text(edit.find).strikethrough().foregroundStyle(.red) + Text("  →  ").foregroundStyle(.secondary) + Text(edit.replace).foregroundStyle(.green))
                        .font(.caption.monospaced()).lineLimit(3)
                    if !edit.rationale.isEmpty { Text(edit.rationale).font(.caption2).foregroundStyle(.secondary) }
                }
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            }
        }
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
        FormLogic.sessionCommand(
            FormLogic.SessionForm(
                folder: folder, name: name, profile: profile, prompt: prompt, promptTools: promptTools, taskContext: taskContext,
                pageStage: pageStage, lockdown: lockdown, claudeArgs: claudeArgs),
            cli: model.cliPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New routed session").font(.title2.bold())
                Text("Starts Claude Code in Terminal through Diorama. Only this session is routed; your other Claude Code sessions and settings are untouched.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], 20)
            Form {
                Section {
                    LabeledContent("Project folder") {
                        HStack {
                            TextField("Project folder", text: $folder).labelsHidden()
                            Button("Choose…") { if let f = chooseFolder() { folder = f } }
                        }
                    }
                    TextField("Name", text: $name, prompt: Text("Optional"))
                }
                Section {
                    Picker("Profile", selection: $profile) {
                        Text("None").tag("")
                        ForEach(model.profiles) { p in Text("\(p.name) (v\(p.currentVersionNumber))").tag(p.name) }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Session prompt")
                        TextEditor(text: $prompt).font(.body).frame(height: 70).scrollContentBackground(.hidden)
                            .padding(4).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                        Text("Optional. Instructions for this session only, applied after the profile's rules.").font(.caption).foregroundStyle(.secondary)
                    }
                    if !prompt.isEmpty {
                        TextField("Applies to tools", text: $promptTools).disabled(pageStage)
                        Toggle("Edit WebFetch pages before summarization", isOn: $pageStage)
                        Toggle("Share the session's task with the rewrite agent", isOn: $taskContext)
                    }
                } header: {
                    Text("Steering")
                }
                Section("Advanced") {
                    Picker("Lockdown", selection: $lockdown) {
                        Text("None").tag(LockdownPreset.none)
                        Text("Block shell network tools").tag(LockdownPreset.network)
                    }
                    TextField("Extra Claude Code arguments", text: $claudeArgs, prompt: Text("e.g. --model sonnet"))
                }
                Section("Command") {
                    Text(command).font(.caption.monospaced()).textSelection(.enabled).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            if model.keyStatus?.configured == false, !profile.isEmpty || !prompt.isEmpty {
                Label("No rewrite API key is configured; matching results will pass through unchanged. Add one in Settings.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.caption).padding(.horizontal, 20)
            }
            HStack {
                Button("Copy Command") { copyToPasteboard(command) }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Open in Terminal") {
                    do {
                        try openInTerminal(command)
                        dismiss()
                    } catch { model.report(error) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(20)
        }
        .frame(width: 620)
        .fixedSize(horizontal: false, vertical: true)
    }
}
