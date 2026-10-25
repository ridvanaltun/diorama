import AppKit
import DioramaCore
import SwiftUI
import UniformTypeIdentifiers

/// Exports decided tool results across sessions as CSV or JSON Lines, for spreadsheets or pandas.
struct ExportDataSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var format: DataExport.Format = .csv
    @State private var days = 30
    @State private var profile = ""
    @State private var includeTrials = true
    @State private var rewrittenOnly = false
    @State private var includeTexts = false
    @State private var rows: Int?
    @State private var working = false

    var key: String { "\(days)|\(profile)|\(includeTrials)|\(rewrittenOnly)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Export Data").font(.title2.bold())
                Text("One row per tool result Diorama decided: session, profile version, tool and input, outcome and reason, rules, rewrite attempts and cost.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            Form {
                Picker("Format", selection: $format) {
                    Text("CSV (spreadsheets)").tag(DataExport.Format.csv)
                    Text("JSON Lines (scripts)").tag(DataExport.Format.jsonl)
                }
                Picker("Time", selection: $days) {
                    Text("Last 7 days").tag(7)
                    Text("Last 30 days").tag(30)
                    Text("Last 90 days").tag(90)
                    Text("All time").tag(0)
                }
                Picker("Profile", selection: $profile) {
                    Text("Any (and no profile)").tag("")
                    ForEach(model.profiles) { Text($0.name).tag($0.id) }
                }
                Toggle("Include experiment trials", isOn: $includeTrials)
                Toggle("Only rewritten tool results", isOn: $rewrittenOnly)
                Toggle(isOn: $includeTexts) {
                    Text("Include original and rewritten text")
                    Text("Makes the file much larger. Texts are what Claude Code's tools returned, so they can contain private content.")
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            HStack {
                Text(rows.map { Fmt.plural($0, "row") } ?? " ").foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export…") { Task { await export() } }.buttonStyle(.borderedProminent).disabled(working || rows == 0)
            }
            .padding(20)
        }
        .frame(width: 560)
        .task(id: key) { rows = (await fetch(format: .jsonl, texts: false))?.rows }
    }

    func fetch(format: DataExport.Format, texts: Bool) async -> DecisionExport? {
        await model.perform {
            try await $0.exportDecisions(format: format, days: days, profile: profile.isEmpty ? nil : profile, includeTrials: includeTrials,
                                         rewrittenOnly: rewrittenOnly, includeTexts: texts)
        }
    }

    func export() async {
        working = true
        defer { working = false }
        let panel = NSSavePanel()
        let stamp = Date().formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = "diorama-decisions-\(stamp).\(format.rawValue)"
        panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : UTType(filenameExtension: "jsonl") ?? .json]
        guard panel.runModal() == .OK, let url = panel.url, let e = await fetch(format: format, texts: includeTexts) else { return }
        do {
            try e.content.write(to: url, atomically: true, encoding: .utf8)
            dismiss()
        } catch { model.report(error) }
    }
}
