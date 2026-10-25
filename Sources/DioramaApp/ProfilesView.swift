import DioramaCore
import SwiftUI

struct ProfilesView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: String?
    @State private var showTemplates = false

    var body: some View {
        HSplitView {
            List(model.profiles, selection: $selection) { p in
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name).font(.headline)
                    Text("v\(p.currentVersionNumber) · \(Fmt.plural(p.ruleCount, "rule"))").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(p.id)
            }
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
            .overlay {
                if model.profiles.isEmpty {
                    ContentUnavailableView {
                        Label("No profiles", systemImage: "slider.horizontal.3")
                    } description: {
                        Text("A profile is a versioned set of rules: which tool results to change, and how.")
                    } actions: {
                        Button("Choose a template") { showTemplates = true }
                    }
                }
            }
            Group {
                if let id = selection {
                    ProfileEditor(profileId: id).id(id)
                } else {
                    ContentUnavailableView("Select a profile", systemImage: "slider.horizontal.3",
                                           description: Text("Every save creates a new immutable version, so sessions and experiments stay reproducible."))
                }
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItem {
                Button { showTemplates = true } label: { Label("New Profile", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $showTemplates) { NewProfileSheet(selection: $selection) }
        .onChange(of: model.wantsNewProfile, initial: true) { _, wants in
            if wants {
                showTemplates = true
                model.wantsNewProfile = false
            }
        }
        .navigationTitle("Profiles")
        .task { if model.snapshotDir != nil, selection == nil { selection = model.profiles.first?.id } }
    }
}

struct NewProfileSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: String?
    @State private var templates: [Profile] = []
    @State private var name = ""
    @State private var chosen = -1

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New profile").font(.title2.bold())
            TextField("Name", text: $name)
            Text("Start from").font(.headline)
            List(selection: Binding(get: { chosen }, set: { chosen = $0 ?? -1 })) {
                Text("Empty profile").tag(-1)
                ForEach(Array(templates.enumerated()), id: \.offset) { i, t in
                    VStack(alignment: .leading) {
                        Text(t.name)
                        Text(t.description).font(.caption).foregroundStyle(.secondary)
                    }.tag(i)
                }
            }
            .frame(height: 200)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    Task {
                        var p = chosen >= 0 && chosen < templates.count ? templates[chosen] : Profile(name: "")
                        if !name.isEmpty { p.name = name }
                        if p.name.isEmpty { p.name = "New profile" }
                        if let v = await model.perform({ try await $0.createProfile(p) }) {
                            await model.refreshProfiles()
                            selection = v.profileId
                            dismiss()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task { templates = await model.perform { try await $0.templates() } ?? [] }
    }
}

/// Edits a working copy of a profile; Save creates a new immutable version.
struct ProfileEditor: View {
    @Environment(AppModel.self) private var model
    let profileId: String
    @State private var detail: ProfileDetail?
    @State private var draft = Profile(name: "")
    @State private var selectedRule: String?
    @State private var showPlayground = false

    var dirty: Bool { detail.map { $0.current.profile != draft } ?? false }

    var body: some View {
        if let detail {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("Name", text: $draft.name).font(.title2.bold()).textFieldStyle(.plain)
                        Text(dirty ? "Unsaved changes to v\(detail.current.number)" : "Version \(detail.current.number) · saved \(Fmt.relative(detail.current.createdAt))")
                            .font(.caption).foregroundStyle(dirty ? .orange : .secondary)
                            .help(detail.current.id)
                    }
                    Spacer()
                    Button { showPlayground = true } label: { Label("Test Rules…", systemImage: "testtube.2") }
                        .help("Try these rules (including unsaved changes) on a past tool result or pasted text")
                    if dirty {
                        Button("Revert") { draft = detail.current.profile }
                        Button("Save as v\(detail.current.number + 1)") { Task { await save() } }.keyboardShortcut("s").buttonStyle(.borderedProminent)
                    }
                }
                .padding(12)
                Divider()
                Form {
                    Section {
                        TextField("Description", text: $draft.description, prompt: Text("What this profile is for"), axis: .vertical).labelsHidden()
                    } header: {
                        Text("Description")
                    }
                    Section("Defaults") {
                        TextField("Rewrite model", text: $draft.defaults.model)
                        Picker("On rewrite failure", selection: $draft.defaults.onFailure) {
                            Text("Pass original through").tag(FailurePolicy.passOriginal)
                            Text("Invalidate experiment trial").tag(FailurePolicy.invalidateTrial)
                        }
                        Stepper("Max input: \(draft.defaults.maxInputChars) chars", value: $draft.defaults.maxInputChars, in: 1000...2_000_000, step: 10_000)
                        Stepper("Timeout: \(Int(draft.defaults.timeoutSeconds)) s", value: $draft.defaults.timeoutSeconds, in: 5...120, step: 5)
                        BudgetField(label: "Daily budget for this profile", value: $draft.defaults.dailyBudgetUSD)
                    }
                    Section {
                        ForEach($draft.rules) { $rule in
                            DisclosureGroup {
                                RuleEditor(rule: $rule)
                            } label: {
                                HStack {
                                    Toggle("", isOn: $rule.enabled).labelsHidden().help(rule.enabled ? "Enabled" : "Disabled")
                                    Text(rule.name.isEmpty ? "Untitled rule" : rule.name).bold().foregroundStyle(rule.enabled ? .primary : .secondary)
                                    Text(rule.match.tools.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                                    if rule.match.stage == .page { Badge(text: "page", color: .teal) }
                                    if rule.isRedaction { Badge(text: "redact", color: .orange) }
                                    if !FormLogic.ruleProblems(rule).isEmpty {
                                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(FormLogic.ruleProblems(rule).joined(separator: "\n"))
                                    }
                                    Spacer()
                                    Button(role: .destructive) { draft.rules.removeAll { $0.id == rule.id } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                                }
                            }
                        }
                        .onMove { draft.rules.move(fromOffsets: $0, toOffset: $1) }
                        if draft.rules.isEmpty {
                            Text("No rules yet: sessions using this profile are recorded but never changed.").font(.callout).foregroundStyle(.secondary)
                        }
                        Button("Add rule") {
                            draft.rules.append(Rule(name: "New rule", match: RuleMatch(tools: ["WebFetch"]), instructions: ""))
                        }
                    } header: {
                        Text("Rules (applied in order; later rules take priority)")
                    }
                    Section("Version history") {
                        ForEach(detail.versions) { v in
                            HStack {
                                Text("v\(v.number)").bold().frame(width: 34, alignment: .leading)
                                Text(v.createdAt.formatted(date: .abbreviated, time: .shortened))
                                Text(Fmt.plural(v.profile.rules.count, "rule")).foregroundStyle(.secondary)
                                Spacer()
                                if v.id == detail.current.id {
                                    Badge(text: "current", color: .green)
                                } else {
                                    Button("Load into editor") { draft = v.profile }.buttonStyle(.borderless)
                                }
                            }
                            .help(v.id)
                        }
                    }
                }
                .formStyle(.grouped)
            }
            .sheet(isPresented: $showPlayground) { PlaygroundSheet(draft: draft) }
        } else {
            ProgressView().task { await load() }
        }
    }

    func load() async {
        if let d = await model.perform({ try await $0.profile(profileId) }) {
            detail = d
            draft = d.current.profile
        }
    }

    func save() async {
        if let d = await model.perform({ try await $0.updateProfile(profileId, draft) }) {
            detail = d
            draft = d.current.profile
            await model.refreshProfiles()
        }
    }
}

struct RuleEditor: View {
    static func label(_ p: RedactSpec.Preset) -> String {
        switch p {
        case .secrets: "Secrets (keys, tokens)"
        case .emails: "Email addresses"
        case .ipAddresses: "IP addresses"
        }
    }

    @Binding var rule: Rule
    @State private var inputText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let problems = FormLogic.ruleProblems(rule)
            TextField("Name", text: $rule.name)
            TextField("Tools (comma-separated, * wildcard)", text: Binding(
                get: { rule.match.tools.joined(separator: ", ") },
                set: { rule.match.tools = FormLogic.parseList($0) }))
            TextField("Input patterns (field=regex, one per line)", text: Binding(
                get: { FormLogic.formatInputPatterns(rule.match.input) },
                set: { rule.match.input = FormLogic.parseInputPatterns($0) }), axis: .vertical)
            TextField("Content regex (optional)", text: Binding(get: { rule.match.content ?? "" }, set: { rule.match.content = $0.isEmpty ? nil : $0 }))
            Picker("Action", selection: Binding(
                get: { rule.isRedaction },
                set: { rule.redact = $0 ? (rule.redact ?? RedactSpec()) : nil })) {
                Text("Rewrite with the AI agent").tag(false)
                Text("Redact (local, no AI)").tag(true)
            }
            .pickerStyle(.segmented)
            Picker("Applies to", selection: $rule.match.stage) {
                Text("Tool result (what Claude receives)").tag(RuleStage.result)
                Text("WebFetch page, before summarization").tag(RuleStage.page)
            }
            Toggle("Also rewrite error results", isOn: $rule.match.includeErrors)
            if rule.match.stage == .page && !rule.match.tools.allSatisfy({ $0 == "WebFetch" }) {
                Text("Page-stage rules only apply to WebFetch.").font(.caption).foregroundStyle(.secondary)
            }
            if let spec = rule.redact {
                Text("Mask before Claude (and any AI rewrite) sees the result").font(.caption)
                HStack(spacing: 16) {
                    ForEach(RedactSpec.Preset.allCases, id: \.self) { preset in
                        Toggle(Self.label(preset), isOn: Binding(
                            get: { spec.presets.contains(preset) },
                            set: { on in
                                var s = rule.redact ?? RedactSpec()
                                s.presets = RedactSpec.Preset.allCases.filter { $0 == preset ? on : s.presets.contains($0) }
                                rule.redact = s
                            }))
                        .toggleStyle(.checkbox)
                    }
                }
                TextField("Custom patterns (regex, one per line)", text: Binding(
                    get: { spec.patterns.joined(separator: "\n") },
                    set: { rule.redact?.patterns = $0.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }),
                          axis: .vertical)
                Text("Matches become [REDACTED:kind]. Redaction runs first, costs nothing, and still applies when the budget is used up or a rewrite fails.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Instructions for the rewrite agent").font(.caption)
                TextEditor(text: $rule.instructions).frame(minHeight: 80).overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                HStack {
                    TextField("Model override (optional)", text: Binding(get: { rule.model ?? "" }, set: { rule.model = $0.isEmpty ? nil : $0 }))
                    Picker("Context", selection: $rule.context) {
                        Text("Minimal").tag(ContextMode.none)
                        Text("Include task").tag(ContextMode.task)
                    }
                }
            }
            ForEach(problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            Text("Rule id: \(rule.id)").font(.caption2.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }
}
