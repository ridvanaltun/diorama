import DioramaCore
import SwiftUI

struct ProfilesView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: String?
    @State private var showTemplates = false

    var body: some View {
        HSplitView {
            List(model.profiles, selection: $selection) { p in
                VStack(alignment: .leading) {
                    Text(p.name).font(.headline)
                    Text("v\(p.currentVersionNumber) · \(p.ruleCount) rule\(p.ruleCount == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                }.tag(p.id)
            }
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
            .overlay {
                if model.profiles.isEmpty {
                    ContentUnavailableView("No profiles", systemImage: "slider.horizontal.3", description: Text("Profiles are versioned sets of global rules. Start from a template."))
                }
            }
            Group {
                if let id = selection {
                    ProfileEditor(profileId: id).id(id)
                } else {
                    ContentUnavailableView("Select a profile", systemImage: "slider.horizontal.3")
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

    var dirty: Bool { detail.map { $0.current.profile != draft } ?? false }

    var body: some View {
        if let detail {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading) {
                        TextField("Name", text: $draft.name).font(.title2.bold()).textFieldStyle(.plain)
                        Text("Current: v\(detail.current.number) · \(detail.current.id)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if dirty {
                        Button("Revert") { draft = detail.current.profile }
                        Button("Save as v\(detail.current.number + 1)") { Task { await save() } }.keyboardShortcut("s").buttonStyle(.borderedProminent)
                    }
                }
                .padding(12)
                Divider()
                Form {
                    Section("Description") { TextField("Description", text: $draft.description, axis: .vertical) }
                    Section("Defaults") {
                        TextField("Rewrite model", text: $draft.defaults.model)
                        Picker("On rewrite failure", selection: $draft.defaults.onFailure) {
                            Text("Pass original through").tag(FailurePolicy.passOriginal)
                            Text("Invalidate experiment trial").tag(FailurePolicy.invalidateTrial)
                        }
                        Stepper("Max input: \(draft.defaults.maxInputChars) chars", value: $draft.defaults.maxInputChars, in: 1000...2_000_000, step: 10_000)
                        Stepper("Timeout: \(Int(draft.defaults.timeoutSeconds)) s", value: $draft.defaults.timeoutSeconds, in: 5...120, step: 5)
                    }
                    Section {
                        ForEach($draft.rules) { $rule in
                            DisclosureGroup {
                                RuleEditor(rule: $rule)
                            } label: {
                                HStack {
                                    Toggle("", isOn: $rule.enabled).labelsHidden()
                                    Text(rule.name.isEmpty ? "Untitled rule" : rule.name).bold()
                                    Text(rule.match.tools.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Button(role: .destructive) { draft.rules.removeAll { $0.id == rule.id } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                                }
                            }
                        }
                        .onMove { draft.rules.move(fromOffsets: $0, toOffset: $1) }
                        Button("Add rule") {
                            draft.rules.append(Rule(name: "New rule", match: RuleMatch(tools: ["WebFetch"]), instructions: ""))
                        }
                    } header: {
                        Text("Rules (applied in order; later rules take priority)")
                    }
                    Section("Version history") {
                        ForEach(detail.versions) { v in
                            HStack {
                                Text("v\(v.number)").bold()
                                Text(v.createdAt.formatted(date: .abbreviated, time: .shortened))
                                Text("\(v.profile.rules.count) rules").foregroundStyle(.secondary)
                                Spacer()
                                Text(v.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                                if v.id != detail.current.id {
                                    Button("Load") { draft = v.profile }.buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            }
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
    @Binding var rule: Rule
    @State private var inputText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Name", text: $rule.name)
            TextField("Tools (comma-separated, * wildcard)", text: Binding(
                get: { rule.match.tools.joined(separator: ", ") },
                set: { rule.match.tools = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
            TextField("Input patterns (field=regex, one per line)", text: Binding(
                get: { rule.match.input.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n") },
                set: { text in
                    var d: [String: String] = [:]
                    for line in text.split(separator: "\n") {
                        let kv = line.split(separator: "=", maxSplits: 1).map(String.init)
                        if kv.count == 2 { d[kv[0].trimmingCharacters(in: .whitespaces)] = kv[1] }
                    }
                    rule.match.input = d
                }), axis: .vertical)
            TextField("Content regex (optional)", text: Binding(get: { rule.match.content ?? "" }, set: { rule.match.content = $0.isEmpty ? nil : $0 }))
            Toggle("Also rewrite error results", isOn: $rule.match.includeErrors)
            Text("Instructions for the rewrite agent").font(.caption)
            TextEditor(text: $rule.instructions).frame(minHeight: 80).overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
            HStack {
                TextField("Model override (optional)", text: Binding(get: { rule.model ?? "" }, set: { rule.model = $0.isEmpty ? nil : $0 }))
                Picker("Context", selection: $rule.context) {
                    Text("Minimal").tag(ContextMode.none)
                    Text("Include task").tag(ContextMode.task)
                }
            }
            Text("Rule id: \(rule.id)").font(.caption2.monospaced()).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}
