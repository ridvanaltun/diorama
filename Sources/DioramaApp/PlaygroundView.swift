import DioramaClient
import DioramaCore
import SwiftUI

/// The rule playground: try a profile (or the editor's unsaved draft) on a past tool result or
/// pasted text. Checking which rules match is free and automatic; a rewrite calls the agent once.
/// Nothing is recorded.
struct PlaygroundSheet: View {
    enum Source: String, CaseIterable {
        case past = "Past tool result"
        case paste = "Paste text"
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The editor's draft; nil lets the user pick a saved profile.
    let draft: Profile?
    @State private var profileRef = ""
    @State private var prompt = ""
    @State private var source: Source
    @State private var recent: [RecentToolResult] = []
    @State private var selected: String?
    @State private var toolName = "WebFetch"
    @State private var toolInput = ""
    @State private var text = ""
    @State private var result: PlaygroundResult?
    @State private var error: String?
    @State private var rewriting = false
    /// Models to compare (comma-separated); fewer than two runs a single rewrite.
    @AppStorage("playgroundCompareModels") private var compareModels = ""

    static let comparableModels = ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5"]
    var compared: [String] { compareModels.split(separator: ",").map(String.init).filter { !$0.isEmpty } }

    init(draft: Profile? = nil, toolUseId: String? = nil) {
        self.draft = draft
        _selected = State(initialValue: toolUseId)
        _source = State(initialValue: .past)
    }

    var request: PlaygroundRequest? {
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var r = PlaygroundRequest(profile: draft, profileRef: draft == nil && !profileRef.isEmpty ? profileRef : nil,
                                  prompt: p.isEmpty ? nil : SessionPrompt(text: p, tools: ["*"]))
        guard r.profile != nil || r.profileRef != nil || r.prompt != nil else { return nil }
        switch source {
        case .past:
            guard let selected else { return nil }
            r.toolUseId = selected
        case .paste:
            guard !text.isEmpty else { return nil }
            r.text = text
            r.toolName = toolName
            r.toolInput = toolInput.trimmingCharacters(in: .whitespaces).isEmpty ? nil : toolInput
        }
        return r
    }

    /// Changes whenever the free rule check should run again.
    var checkKey: String {
        [draft.map { String(describing: $0) } ?? "", profileRef, prompt, source.rawValue, selected ?? "", toolName, toolInput, text].joined(separator: "\u{1F}")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Test rules").font(.title2.bold())
                Text("See which rules match and what the rewrite agent would do, before using them in a session. Nothing is recorded; only “Run rewrite” calls the API.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], 20)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    rulesSection
                    contentSection
                    if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
                    if let result { ResultView(result: result) }
                }
                .padding(20)
            }
            HStack {
                if let m = result?.model, compared.count < 2 { Text("Rewrite model: \(m)").font(.caption).foregroundStyle(.secondary) }
                Menu {
                    Section("Run the rewrite on each of") {
                        ForEach(Self.comparableModels, id: \.self) { m in
                            Toggle(m, isOn: Binding(
                                get: { compared.contains(m) },
                                set: { on in compareModels = (on ? compared + [m] : compared.filter { $0 != m }).joined(separator: ",") }))
                        }
                    }
                    Text("Each model is one paid call. Pick two or more to compare.")
                } label: {
                    Label(compared.count >= 2 ? "Comparing \(compared.count) models" : "Compare models", systemImage: "square.split.3x1")
                }
                .fixedSize()
                .help("Run the same rewrite on several models side by side: result, time and cost")
                Spacer()
                Button("Close") { dismiss() }
                Button {
                    Task { await run(rewrite: true) }
                } label: {
                    if rewriting { ProgressView().controlSize(.small) } else { Text(compared.count >= 2 ? "Run on \(compared.count) models" : "Run rewrite") }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(request == nil || rewriting || result?.model == nil)
                .help(result?.model == nil ? "No rule matches this content" : "Calls the rewrite agent once (small cost); nothing is recorded")
            }
            .padding(20)
        }
        .frame(width: 760, height: 760)
        .task {
            recent = await model.perform { try await $0.recentToolResults(limit: 100) } ?? []
            if model.snapshotDir != nil, selected == nil { selected = recent.first { $0.decision.toolName == "WebFetch" }?.id }
        }
        .task(id: checkKey) {
            try? await Task.sleep(for: .milliseconds(250))  // debounce typing
            guard !Task.isCancelled else { return }
            await run(rewrite: false)
        }
    }

    @ViewBuilder var rulesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rules").font(.headline)
            if let draft {
                Label("The editor's current draft of “\(draft.name)”, including unsaved changes (\(Fmt.plural(draft.rules.count, "rule")))", systemImage: "pencil.and.list.clipboard")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Picker("Profile", selection: $profileRef) {
                    Text("None").tag("")
                    ForEach(model.profiles) { Text("\($0.name) (v\($0.currentVersionNumber))").tag($0.name) }
                }
                .frame(maxWidth: 360)
            }
            TextField("Session prompt to test as well (optional; applies to every tool)", text: $prompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder var contentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Content").font(.headline)
                Spacer()
                Picker("Source", selection: $source) {
                    ForEach(Source.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            switch source {
            case .past:
                if recent.isEmpty {
                    Text("No tool results recorded yet. Paste text instead, or run a session first.").font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    List(recent, selection: $selected) { r in
                        HStack(spacing: 8) {
                            Image(systemName: Fmt.toolIcon(r.decision.toolName)).frame(width: 18).foregroundStyle(.secondary)
                            Text(Fmt.toolName(r.decision.toolName)).fontWeight(.medium)
                            if let t = Fmt.toolTarget(r.decision.toolName, r.decision.toolInput) {
                                Text(t).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Text(r.sessionName).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                            Badge(text: r.decision.outcome.rawValue, color: r.decision.outcome.color)
                        }
                        .tag(r.decision.toolUseId)
                    }
                    .frame(height: 170)
                    .listStyle(.bordered)
                }
            case .paste:
                HStack {
                    TextField("Tool", text: $toolName).frame(width: 140)
                    TextField(#"Tool input JSON, e.g. {"url": "https://example.com/docs"}"#, text: $toolInput)
                }
                .textFieldStyle(.roundedBorder)
                TextEditor(text: $text).font(.body.monospaced()).frame(height: 130).scrollContentBackground(.hidden)
                    .padding(4).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            }
        }
    }

    func run(rewrite: Bool) async {
        guard var r = request else {
            result = nil
            return
        }
        r.rewrite = rewrite
        if rewrite, compared.count >= 2 { r.models = compared }
        if rewrite { rewriting = true }
        defer { rewriting = false }
        guard let client = model.client else { return }
        do {
            result = try await client.playground(r)
            error = nil
        } catch {
            self.error = (error as? ClientError)?.message ?? String(describing: error)
        }
    }
}

private struct ResultView: View {
    let result: PlaygroundResult

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Which rules match").font(.headline)
                ForEach(result.checks, id: \.ruleId) { c in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: c.matches ? "checkmark.circle.fill" : "minus.circle").foregroundStyle(c.matches ? .green : .secondary)
                        Text(c.name).fontWeight(.medium)
                        Text(c.reason).foregroundStyle(.secondary).font(.callout)
                    }
                }
            }
            if let note = result.note { Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary) }
            if let all = result.comparisons {
                ModelComparisonView(original: result.originalText, rewrites: all)
            } else if let rw = result.rewrite {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Rewrite").font(.headline)
                        Badge(text: rw.status.rawValue, color: rw.status == .succeeded ? .purple : (rw.status == .unchanged ? .secondary : .red))
                        Spacer()
                        Text("\(rw.model) · \(Fmt.duration(rw.latencyMs)) · \(Fmt.money(rw.costUSD))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if let e = rw.explanation { Text(e).font(.callout) }
                    if let err = rw.error { Text(err).font(.callout).foregroundStyle(.red) }
                    if let r = rw.replacementText {
                        DiffText(original: result.originalText, replacement: r).padding(10)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    }
                    ForEach(Array(rw.edits.enumerated()), id: \.offset) { _, edit in
                        (Text(edit.find).strikethrough().foregroundStyle(.red) + Text("  →  ").foregroundStyle(.secondary) + Text(edit.replace).foregroundStyle(.green))
                            .font(.caption.monospaced()).lineLimit(3)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Content").font(.headline)
                    MonoBlock(text: result.originalText).frame(minHeight: 80, maxHeight: 200)
                }
            }
        }
    }
}

/// The same rewrite on several models: what each produced, how long it took, what it cost.
struct ModelComparisonView: View {
    let original: String
    let rewrites: [PlaygroundRewrite]

    var fastest: String? { rewrites.filter { $0.status == .succeeded }.min { $0.latencyMs < $1.latencyMs }?.model }
    var cheapest: String? { rewrites.filter { $0.status == .succeeded && $0.costUSD != nil }.min { ($0.costUSD ?? 0) < ($1.costUSD ?? 0) }?.model }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Model comparison").font(.headline)
            let total = rewrites.compactMap(\.costUSD).reduce(0, +)
            Text("\(rewrites.count) models · total \(Fmt.money(total)). Results vary between runs; compare a few times before choosing.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(rewrites.enumerated()), id: \.offset) { _, rw in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(rw.model).font(.callout.monospaced().weight(.medium))
                        Badge(text: rw.status.rawValue, color: rw.status == .succeeded ? .purple : (rw.status == .unchanged ? .secondary : .red))
                        if rw.model == fastest, rewrites.count > 1 { Badge(text: "fastest", color: .blue) }
                        if rw.model == cheapest, rewrites.count > 1 { Badge(text: "cheapest", color: .green) }
                        Spacer()
                        Text("\(Fmt.duration(rw.latencyMs)) · \(Fmt.money(rw.costUSD))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if let e = rw.explanation { Text(e).font(.callout) }
                    if let err = rw.error { Text(err).font(.callout).foregroundStyle(.red) }
                    if let r = rw.replacementText {
                        DiffText(original: original, replacement: r).padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(10)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}
