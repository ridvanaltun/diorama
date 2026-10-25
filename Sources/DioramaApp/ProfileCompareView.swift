import DioramaCore
import SwiftUI

/// What changed between two versions of a profile (or the saved version and unsaved edits).
struct ProfileCompareSheet: View {
    @Environment(\.dismiss) private var dismiss
    let from: Profile
    let fromLabel: String
    let to: Profile
    let toLabel: String

    var comparison: ProfileComparison { .compare(from, to) }

    var body: some View {
        let c = comparison
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(fromLabel) → \(toLabel)").font(.title2.bold())
                Text(c.isEmpty ? "No differences." : summary(c)).font(.callout).foregroundStyle(.secondary)
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !c.fields.isEmpty {
                        card(title: "Profile", icon: "slider.horizontal.3", color: .secondary, fields: c.fields)
                    }
                    ForEach(c.rules) { r in
                        card(title: r.name, icon: Self.icon(r.kind), color: Self.color(r.kind), badge: Self.label(r), fields: r.fields)
                    }
                }
                .padding(20)
            }
            Divider()
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
        }
        .frame(width: 720, height: 640)
    }

    func summary(_ c: ProfileComparison) -> String {
        let counts: [(ProfileComparison.RuleChange.Kind, String)] = [(.added, "added"), (.removed, "removed"), (.changed, "changed"), (.moved, "moved")]
        var parts = counts.compactMap { k, word in
            let n = c.rules.filter { $0.kind == k }.count
            return n > 0 ? "\(Fmt.plural(n, "rule")) \(word)" : nil
        }
        if !c.fields.isEmpty { parts.insert(Fmt.plural(c.fields.count, "profile setting") + " changed", at: 0) }
        return parts.joined(separator: " · ")
    }

    func card(title: String, icon: String, color: Color, badge: String? = nil, fields: [ProfileComparison.FieldChange]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(color).frame(width: 18)
                Text(title).fontWeight(.medium)
                Spacer()
                if let badge { Badge(text: badge, color: color) }
            }
            ForEach(fields) { f in
                VStack(alignment: .leading, spacing: 3) {
                    Text(Self.fieldLabel(f.path)).font(.caption.bold()).foregroundStyle(.secondary)
                    if (f.old?.count ?? 0) + (f.new?.count ?? 0) > 80 || (f.old ?? "").contains("\n") || (f.new ?? "").contains("\n") {
                        DiffText(original: f.old ?? "", replacement: f.new ?? "").padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    } else {
                        HStack(spacing: 6) {
                            Text(f.old ?? "none").strikethrough(f.old != nil).foregroundStyle(f.old == nil ? .tertiary : .secondary)
                            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                            Text(f.new ?? "none").foregroundStyle(f.new == nil ? .tertiary : .primary)
                        }
                        .font(.callout.monospaced())
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }

    static func icon(_ k: ProfileComparison.RuleChange.Kind) -> String {
        switch k {
        case .added: "plus.circle.fill"
        case .removed: "minus.circle.fill"
        case .changed: "pencil.circle.fill"
        case .moved: "arrow.up.arrow.down.circle.fill"
        }
    }

    static func color(_ k: ProfileComparison.RuleChange.Kind) -> Color {
        switch k {
        case .added: .green
        case .removed: .red
        case .changed: .blue
        case .moved: .secondary
        }
    }

    static func label(_ r: ProfileComparison.RuleChange) -> String {
        r.kind == .changed && r.moved ? "changed, moved" : r.kind.rawValue
    }

    /// `match.input.url` → "Input pattern: url", `defaults.model` → "Default: model".
    static func fieldLabel(_ path: String) -> String {
        let names = ["match.tools": "Tools", "match.content": "Content regex", "match.stage": "Applies to", "match.requestClass": "Request class",
                     "match.classifier.question": "Classifier question", "match.classifier.model": "Classifier model", "instructions": "Instructions",
                     "enabled": "Enabled", "model": "Rewrite model", "effort": "Effort", "context": "Context", "name": "Name", "description": "Description",
                     "redact.presets": "Redact presets", "redact.patterns": "Redact patterns"]
        if let n = names[path] { return n }
        if path.hasPrefix("match.input.") { return "Input pattern: " + path.dropFirst("match.input.".count) }
        if path.hasPrefix("defaults.") { return "Default: " + path.dropFirst("defaults.".count) }
        return path
    }
}
