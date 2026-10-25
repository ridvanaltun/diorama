import AppKit
import DioramaClient
import DioramaCore
import SwiftUI

/// What-if replay: run a session's recorded tool results through other rules (another profile,
/// another version, or a prompt) and compare with what the session did. Checking is free; the
/// rewrite run is capped and shows its estimate first. Nothing is recorded.
struct WhatIfSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let session: SessionInfo
    @State private var profileRef: String
    @State private var versions: [ProfileVersionInfo] = []
    @State private var versionId = ""
    @State private var prompt = ""
    @State private var result: WhatIfResult?
    @State private var error: String?
    @State private var running = false
    @State private var differencesOnly = true

    init(session: SessionInfo) {
        self.session = session
        _profileRef = State(initialValue: session.profileName ?? "")
    }

    var request: WhatIfRequest? {
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = WhatIfRequest(
            sessionId: session.id, profileRef: profileRef.isEmpty ? nil : profileRef, profileVersionId: versionId.isEmpty ? nil : versionId,
            prompt: p.isEmpty ? nil : SessionPrompt(text: p, tools: ["*"]))
        return r.profileRef == nil && r.profileVersionId == nil && r.prompt == nil ? nil : r
    }

    var checkKey: String { [profileRef, versionId, prompt].joined(separator: "\u{1F}") }

    var shown: [WhatIfItem] {
        (result?.items ?? []).filter { !differencesOnly || ![.sameUnchanged, .sameRewrite].contains($0.change) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What if…").font(.title2.bold())
                Text("Run “\(session.name)”'s \(Fmt.plural(session.stats.toolResults, "tool result")) through other rules and compare with what the session did. Checking is free; nothing is recorded.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], 20)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Profile", selection: $profileRef) {
                        Text("None").tag("")
                        ForEach(model.profiles) { Text($0.name).tag($0.name) }
                    }
                    .frame(maxWidth: 300)
                    Picker("Version", selection: $versionId) {
                        Text("Current").tag("")
                        ForEach(versions) { v in
                            Text("v\(v.number)" + (v.id == session.profileVersionId ? " (this session's)" : "")).tag(v.id)
                        }
                    }
                    .frame(maxWidth: 220)
                    .disabled(profileRef.isEmpty)
                }
                TextField("Session prompt to add (optional; applies to every tool)", text: $prompt, axis: .vertical).textFieldStyle(.roundedBorder)
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    if let r = result { summary(r) }
                    ForEach(shown) { WhatIfRow(item: $0) }
                    if result != nil, shown.isEmpty {
                        Text(differencesOnly ? "No differences." : "No tool results with text.").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 20)
                    }
                }
                .padding(20)
            }
            Divider()
            HStack {
                Toggle("Only differences", isOn: $differencesOnly).toggleStyle(.checkbox)
                Spacer()
                Button("Copy as Markdown") { if let r = result { copyToPasteboard(Self.markdown(r)) } }.disabled(result == nil)
                Button("Close") { dismiss() }
                Button {
                    Task { await run(rewrite: true) }
                } label: {
                    if running { ProgressView().controlSize(.small) } else { Text(runLabel) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(running || (result?.calls ?? 0) == 0 || result?.rewrite == true)
                .help("Calls the rewrite agent for each matching result (at most 25)")
            }
            .padding(20)
        }
        .frame(width: 820, height: 780)
        .task(id: profileRef) {
            versionId = ""
            versions = profileRef.isEmpty ? [] : (await model.perform { try await $0.profile(profileRef) }?.versions ?? [])
        }
        .task(id: checkKey) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await run(rewrite: false)
        }
    }

    var runLabel: String {
        guard let r = result, r.calls > 0 else { return "Run rewrites" }
        return "Run \(Fmt.plural(r.calls, "rewrite")) (≈\(Fmt.moneyRange(r.estimateLowUSD, r.estimateHighUSD)))"
    }

    func summary(_ r: WhatIfResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(r.rulesLabel) on \(Fmt.plural(r.items.count, "tool result"))" + (r.rewrite ? " · cost \(Fmt.money(r.costUSD))" : "")).font(.headline)
            let order: [WhatIfChange] = [.nowRewritten, .rewrittenDifferently, .noLongerRewritten, .wouldRewrite, .sameRewrite, .sameUnchanged, .skipped, .failed]
            FlowChips(items: order.compactMap { c in r.count(c) > 0 ? ("\(r.count(c)) \(c.label)", c.color) : nil })
            if !r.rewrite, r.calls > 0 {
                Text("Matching results show what the rules select. Run the rewrites to see the actual text.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    func run(rewrite: Bool) async {
        guard var r = request else {
            result = nil
            return
        }
        r.rewrite = rewrite
        running = true
        defer { running = false }
        guard let client = model.client else { return }
        do {
            result = try await client.whatIf(r)
            error = nil
        } catch {
            self.error = (error as? ClientError)?.message ?? String(describing: error)
        }
    }

    static func markdown(_ r: WhatIfResult) -> String {
        var out = ["# What if: \(r.rulesLabel) on “\(r.sessionName)”", ""]
        out.append(WhatIfChange.allCases.compactMap { c in r.count(c) > 0 ? "- \(r.count(c)) \(c.label)" : nil }.joined(separator: "\n"))
        if r.rewrite { out.append("\nRewrite cost: \(Fmt.money(r.costUSD))") }
        for i in r.items where ![.sameUnchanged, .sameRewrite].contains(i.change) {
            out.append("\n## \(i.toolName) \(Fmt.toolTarget(i.toolName, i.toolInput) ?? i.toolUseId): \(i.change.label)")
            out.append("Before: \(i.before.rawValue) (\(i.beforeReason))")
            if !i.matchedRules.isEmpty { out.append("Matching rules: \(i.matchedRules.joined(separator: ", "))") }
            if let e = i.afterExplanation { out.append("New rewrite: \(e)") }
            if let t = i.afterText { out.append("\n```\n\(t)\n```") }
        }
        return out.joined(separator: "\n")
    }
}

extension WhatIfChange {
    var color: Color {
        switch self {
        case .nowRewritten, .rewrittenDifferently: .purple
        case .noLongerRewritten: .orange
        case .wouldRewrite: .blue
        case .failed: .red
        default: .secondary
        }
    }
}

private struct FlowChips: View {
    let items: [(String, Color)]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(items, id: \.0) { Badge(text: $0.0, color: $0.1) }
        }
    }
}

private struct WhatIfRow: View {
    let item: WhatIfItem
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                if !item.matchedRules.isEmpty { Text("Matching rules: \(item.matchedRules.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary) }
                Text("Before: \(item.before.rawValue) — \(item.beforeReason)").font(.caption).foregroundStyle(.secondary)
                if let e = item.afterExplanation { Text("New rewrite: \(e)").font(.caption) }
                if let e = item.afterError { Text(e).font(.caption).foregroundStyle(.red) }
                let before = item.beforeText ?? item.originalText
                let after = item.afterText ?? (item.change == .noLongerRewritten ? item.originalText : nil)
                if let after, after != before {
                    Text("What Claude saw → what it would see").font(.caption.bold())
                    DiffText(original: before, replacement: after).padding(8)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                } else {
                    MonoBlock(text: before).frame(minHeight: 50, maxHeight: 160)
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: Fmt.toolIcon(item.toolName)).frame(width: 18).foregroundStyle(.secondary)
                Text(Fmt.toolName(item.toolName)).fontWeight(.medium)
                if let t = Fmt.toolTarget(item.toolName, item.toolInput) { Text(t).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                Spacer()
                Badge(text: item.before.rawValue, color: item.before.color)
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                Badge(text: item.change.label, color: item.change.color)
            }
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }
}
