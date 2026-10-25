import DioramaCore
import SwiftUI

/// Impact of the open session's rewritten results, for rows and the audit record.
private struct ImpactsKey: EnvironmentKey {
    static let defaultValue: [String: DecisionImpact] = [:]
}

extension EnvironmentValues {
    var impacts: [String: DecisionImpact] {
        get { self[ImpactsKey.self] }
        set { self[ImpactsKey.self] = newValue }
    }
}

extension DecisionImpact {
    var color: Color {
        if signals.contains(.used) { return .green }
        if !signals.isEmpty { return .orange }
        return .secondary
    }

    var help: String {
        switch label {
        case "used": "Claude repeated text this rewrite introduced (heuristic)"
        case "questioned": "Claude's later text questions the content (heuristic)"
        case "checked": "Claude re-fetched the page or ran a network command afterwards (heuristic)"
        case "original surfaced": "Text the rewrite removed shows up in what Claude wrote later (heuristic)"
        case "no sign": "Claude responded, with no sign of the rewritten text (heuristic)"
        case "pending": "Claude hasn't responded yet"
        default: "Hook mode doesn't see Claude's replies; later tool calls showed nothing"
        }
    }
}

/// Small badge after "rewritten" in a timeline row.
struct ImpactBadge: View {
    @Environment(\.impacts) private var impacts
    let toolUseId: String

    var body: some View {
        if let i = impacts[toolUseId], i.status != .pending {
            Badge(text: i.label, color: i.color).help(i.help)
        }
    }
}

/// "Did Claude use it?" in the audit record.
struct ImpactSection: View {
    @Environment(\.impacts) private var impacts
    let toolUseId: String

    var body: some View {
        if let i = impacts[toolUseId] {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Did Claude use it?").font(.headline)
                    Badge(text: i.label, color: i.color)
                    Text("heuristic").font(.caption).foregroundStyle(.tertiary)
                }
                if i.evidence.isEmpty {
                    Text(i.help).font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(i.evidence, id: \.self) { Label($0, systemImage: "text.magnifyingglass").font(.callout) }
                }
            }
        }
    }
}
