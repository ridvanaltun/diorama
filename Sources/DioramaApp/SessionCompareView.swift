import DioramaCore
import SwiftUI

/// Two sessions side by side. For a measured comparison with a control, the Experiments screen.
struct SessionCompareSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let a: String
    let b: String
    var sample: SessionComparison?
    @State private var comparison: SessionComparison?
    @State private var diffAnswers = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let c = comparison ?? sample {
                content(c)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Text("A side-by-side look, not a measurement: use an experiment for repeated trials with a control.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(width: 820, height: 720)
        .task { if sample == nil { comparison = await model.perform { try await $0.compareSessions(a, b) } } }
    }

    func content(_ c: SessionComparison) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    sessionCard("A", c.a)
                    sessionCard("B", c.b)
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("").gridColumnAlignment(.leading)
                        Text("A").font(.caption.bold()).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        Text("B").font(.caption.bold()).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        Text("B − A").font(.caption.bold()).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(c.metrics) { m in
                        GridRow {
                            Text(m.label)
                            Text(Self.value(m.a, m.unit)).monospacedDigit()
                            Text(Self.value(m.b, m.unit)).monospacedDigit()
                            Text(Self.delta(m)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    if !c.tools.isEmpty {
                        Divider().gridCellUnsizedAxes(.horizontal)
                        ForEach(c.tools) { t in
                            GridRow {
                                Label(Fmt.toolName(t.tool), systemImage: Fmt.toolIcon(t.tool))
                                Text("\(t.a)").monospacedDigit()
                                Text("\(t.b)").monospacedDigit()
                                Text(t.b == t.a ? "" : (t.b > t.a ? "+" : "") + "\(t.b - t.a)").monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(12)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                HStack(alignment: .top, spacing: 12) {
                    rules("Rules that rewrote in A", c.rulesA)
                    rules("Rules that rewrote in B", c.rulesB)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Claude's final answers").font(.headline)
                        Spacer()
                        Toggle("Show differences", isOn: $diffAnswers).toggleStyle(.checkbox)
                            .disabled(c.finalAnswerA == nil || c.finalAnswerB == nil)
                    }
                    if diffAnswers, let x = c.finalAnswerA, let y = c.finalAnswerB {
                        DiffText(original: x, replacement: y).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    } else {
                        HStack(alignment: .top, spacing: 12) {
                            answer("A", c.finalAnswerA)
                            answer("B", c.finalAnswerB)
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    func sessionCard(_ label: String, _ s: SessionInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 1).background(.quaternary, in: Capsule())
                Text(s.name).font(.headline).lineLimit(1)
            }
            Text(s.profileName.map { "\($0) · v\(s.profileVersionNumber ?? 0)" } ?? (s.prompt != nil ? "Session prompt" : "No rules")).font(.caption).foregroundStyle(.secondary)
            Text(s.createdAt.formatted(date: .abbreviated, time: .shortened) + (s.isHook ? " · hook mode" : "")).font(.caption).foregroundStyle(.secondary)
            if let tags = s.tags, !tags.isEmpty { HStack { ForEach(tags, id: \.self) { TagChip(text: $0) } } }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }

    func rules(_ title: String, _ names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            Text(names.isEmpty ? "None" : names.joined(separator: ", ")).font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func answer(_ label: String, _ text: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.bold()).foregroundStyle(.secondary)
            MonoBlock(text: text ?? "(no final answer recorded)").frame(minHeight: 120, maxHeight: 260)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func value(_ v: Double?, _ unit: String) -> String {
        guard let v else { return "—" }
        switch unit {
        case "usd": return Fmt.money(v)
        case "seconds": return v < 60 ? String(format: "%.0f s", v) : String(format: "%.1f min", v / 60)
        default: return v.formatted(.number.grouping(.automatic))
        }
    }

    static func delta(_ m: SessionComparison.Metric) -> String {
        guard let a = m.a, let b = m.b, a != b else { return "" }
        let d = b - a
        let sign = d > 0 ? "+" : "−"
        return sign + value(abs(d), m.unit)
    }
}

/// "Compare with…" in a session's header: recent sessions, same folder first.
struct CompareWithMenu: View {
    @Environment(AppModel.self) private var model
    let session: SessionInfo
    @Binding var other: String?

    var candidates: [SessionInfo] {
        let rest = model.sessions.filter { $0.id != session.id }
        return (rest.filter { $0.cwd == session.cwd } + rest.filter { $0.cwd != session.cwd }).prefix(15).map { $0 }
    }

    var body: some View {
        Menu {
            Section("Compare “\(session.name)” with") {
                ForEach(candidates) { s in
                    Button("\(s.name) · \(Fmt.relative(s.createdAt))" + (s.profileName.map { " · \($0)" } ?? "")) { other = s.id }
                }
            }
        } label: {
            Label("Compare…", systemImage: "rectangle.split.2x1")
        }
        .controlSize(.small).fixedSize()
        .disabled(candidates.isEmpty)
        .help("Put this session side by side with another one")
    }
}
