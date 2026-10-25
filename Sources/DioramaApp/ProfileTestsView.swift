import DioramaCore
import SwiftUI

/// The profile editor's rule tests: sample tool results and which rules should match them.
/// They run on every edit (matching only, no model calls).
struct ProfileTestsSection: View {
    @Environment(AppModel.self) private var model
    @Binding var draft: Profile
    @State private var results: [String: ProfileTestResult] = [:]

    var tests: [ProfileTestCase] { draft.tests ?? [] }

    var body: some View {
        Section {
            if tests.isEmpty {
                Text("No tests yet. A test is a sample tool result plus the rules that should match it; it shows right away when an edit changes what matches.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(tests) { t in
                TestCaseRow(test: binding(t.id), rules: draft.rules, result: results[t.id]) {
                    draft.tests = tests.filter { $0.id != t.id }
                    if draft.tests?.isEmpty == true { draft.tests = nil }
                }
            }
            Button("Add test") {
                draft.tests = tests + [ProfileTestCase(name: "Test \(tests.count + 1)", text: "", expectMatch: [])]
            }
        } header: {
            HStack {
                Text("Rule tests")
                Spacer()
                if !tests.isEmpty {
                    let passed = tests.filter { results[$0.id]?.passed == true }.count
                    Badge(text: "\(passed)/\(tests.count) passing", color: passed == tests.count ? .green : .red)
                }
            }
        }
        .task(id: draft) {
            guard !tests.isEmpty else { return results = [:] }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let r = try? await model.client?.runProfileTests(profile: draft) else { return }
            results = Dictionary(r.map { ($0.caseId, $0) }, uniquingKeysWith: { x, _ in x })
        }
    }

    func binding(_ id: String) -> Binding<ProfileTestCase> {
        Binding(
            get: { tests.first { $0.id == id } ?? ProfileTestCase(id: id, name: "", text: "", expectMatch: []) },
            set: { new in draft.tests = tests.map { $0.id == id ? new : $0 } })
    }
}

private struct TestCaseRow: View {
    @Binding var test: ProfileTestCase
    let rules: [Rule]
    let result: ProfileTestResult?
    let remove: () -> Void
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Name", text: $test.name)
                HStack {
                    TextField("Tool", text: $test.toolName).frame(maxWidth: 180)
                    Picker("Stage", selection: $test.stage) {
                        Text("Tool result").tag(RuleStage.result)
                        Text("Raw page").tag(RuleStage.page)
                        Text("Tool input").tag(RuleStage.input)
                    }
                    .fixedSize()
                    Toggle("Error result", isOn: $test.isError)
                }
                TextField("Tool input JSON (optional), e.g. {\"url\":\"https://docs.example.com\"}",
                          text: Binding(get: { test.toolInput ?? "" }, set: { test.toolInput = $0.isEmpty ? nil : $0 }))
                    .font(.callout.monospaced())
                TextEditor(text: $test.text).font(.callout.monospaced()).frame(height: 90)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                Text("Should match").font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(rules) { r in
                    Toggle(r.name.isEmpty ? "Untitled rule" : r.name, isOn: Binding(
                        get: { test.expectMatch.contains(r.id) },
                        set: { on in test.expectMatch = on ? test.expectMatch + [r.id] : test.expectMatch.filter { $0 != r.id } }))
                        .toggleStyle(.checkbox)
                }
                HStack {
                    if let result, !result.passed {
                        Button("Expect what matches now") {
                            test.expectMatch = rules.filter { result.matched.contains($0.name) }.map(\.id)
                        }
                        .help("Accept the current behavior as correct")
                    }
                    Spacer()
                    Button("Delete test", role: .destructive, action: remove)
                }
            }
            .padding(.top, 4)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: result == nil ? "circle.dotted" : result!.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result == nil ? Color.secondary : result!.passed ? Color.green : Color.red)
                    Text(test.name.isEmpty ? "Untitled test" : test.name).fontWeight(.medium)
                    Text(test.toolName).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let result { Text(result.matched.isEmpty ? "matches nothing" : result.matched.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                ForEach(result?.problems ?? [], id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
            }
        }
    }
}
