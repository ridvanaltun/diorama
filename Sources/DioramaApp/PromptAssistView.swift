import DioramaCore
import SwiftUI

/// Write with AI: describe what Claude should see differently, get a session prompt for the
/// rewrite agent, and use it in the form. Calls the default rewrite model with the rewrite key.
struct PromptAssistSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let currentPrompt: String
    let currentTools: String
    let use: (PromptSuggestion) -> Void
    @State private var goal = ""
    @State private var result: PromptAssistResult?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Write the Prompt with AI").font(.title2.bold())
            Text(currentPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                 ? "Describe what Claude should see differently, in your own words. The rewrite model drafts the session prompt and picks the tools it applies to."
                 : "Describe what to change about the current prompt, or what Claude should see differently. The rewrite model improves the prompt you have.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $goal)
                .font(.body).frame(height: 80).scrollContentBackground(.hidden)
                .padding(4).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if goal.isEmpty {
                        Text("e.g. Claude should think version 2 of the library is deprecated and recommend version 3")
                            .foregroundStyle(.tertiary).padding(.horizontal, 9).padding(.vertical, 4).allowsHitTesting(false)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Text("Uses \(model.settings.defaultModel) with your rewrite key; counts toward the daily budget.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { Task { await suggest() } } label: {
                    if working { ProgressView().controlSize(.small) } else { Text(result?.suggestion == nil ? "Suggest" : "Suggest Again") }
                }
                .disabled(working || goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let r = result {
                if let s = r.suggestion {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(s.prompt).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            Label(s.tools.joined(separator: ", "), systemImage: "wrench.and.screwdriver").font(.caption).foregroundStyle(.secondary)
                            if !s.explanation.isEmpty { Text(s.explanation).font(.caption).foregroundStyle(.secondary) }
                            Text("\(r.model) · \(Fmt.money(r.costUSD))").font(.caption2).foregroundStyle(.tertiary)
                        }
                        .padding(4)
                    }
                } else if let e = r.error {
                    Label(e, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use This") {
                    if let s = result?.suggestion { use(s) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(result?.suggestion == nil)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    func suggest() async {
        working = true
        defer { working = false }
        let tools = FormLogic.parseList(currentTools)
        let current = currentPrompt
        result = await model.perform { try await $0.assistPrompt(goal: goal, currentPrompt: current, tools: tools) } ?? result
    }
}
