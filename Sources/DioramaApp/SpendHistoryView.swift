import DioramaCore
import SwiftUI

/// Settings: rewrite-agent spending per day, stacked by where it went.
struct SpendHistorySection: View {
    @Environment(AppModel.self) private var model
    @AppStorage("spendHistoryDays") private var days = 30
    @State private var history: SpendHistory?
    @State private var hovered: SpendHistory.Day?

    var body: some View {
        Section {
            if let h = history {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(Fmt.money(h.totalUSD)).font(.title3.bold()).monospacedDigit()
                        Text("in the last \(Fmt.plural(days, "day"))").foregroundStyle(.secondary)
                        Spacer()
                        if let d = hovered {
                            Text("\(d.day.formatted(.dateTime.weekday(.abbreviated).month().day())): \(Fmt.money(d.totalUSD)) · \(Fmt.plural(d.calls, "call"))")
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    SpendBars(days: h.days, hovered: $hovered)
                        .frame(height: 90)
                    HStack(spacing: 12) {
                        legend("Sessions", .purple)
                        legend("Experiment trials", .blue)
                        legend("Playground & what-if", .teal)
                    }
                    .font(.caption)
                    let byProfile = Self.byProfile(h)
                    if !byProfile.isEmpty {
                        Divider()
                        ForEach(byProfile.prefix(5), id: \.0) { name, usd in
                            HStack {
                                Text(name)
                                Spacer()
                                Text(Fmt.money(usd)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                    }
                }
                .padding(.vertical, 4)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        } header: {
            HStack {
                Text("Spending")
                Spacer()
                Picker("Window", selection: $days) {
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                .labelsHidden().fixedSize()
            }
        } footer: {
            Text("Rewrite-agent calls billed to your key. The daily budget counts sessions and previews; experiment trials run against their own approved estimate.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task(id: "\(days)/\(model.eventTick / 20)") { history = await model.perform { try await $0.spendHistory(days: days) } }
    }

    func legend(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(text).foregroundStyle(.secondary)
        }
    }

    static func byProfile(_ h: SpendHistory) -> [(String, Double)] {
        var out: [String: Double] = [:]
        for d in h.days { for (k, v) in d.byProfile { out[k, default: 0] += v } }
        return out.sorted { $0.value > $1.value }
    }
}

/// Stacked daily bars, scaled to the busiest day. Hover a bar for its numbers.
private struct SpendBars: View {
    let days: [SpendHistory.Day]
    @Binding var hovered: SpendHistory.Day?

    var body: some View {
        GeometryReader { g in
            let peak = max(days.map(\.totalUSD).max() ?? 0, 0.000_001)
            let gap: CGFloat = days.count > 60 ? 1 : 2
            let w = max(1, (g.size.width - gap * CGFloat(days.count - 1)) / CGFloat(max(days.count, 1)))
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(days) { d in
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        segment(d.previewsUSD, .teal, peak, g.size.height)
                        segment(d.trialsUSD, .blue, peak, g.size.height)
                        segment(d.sessionsUSD, .purple, peak, g.size.height)
                        Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 1)
                    }
                    .frame(width: w)
                    .background(hovered?.day == d.day ? Color.primary.opacity(0.06) : .clear)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { hovered = d } else if hovered?.day == d.day { hovered = nil }
                    }
                }
            }
        }
    }

    @ViewBuilder func segment(_ v: Double, _ color: Color, _ peak: Double, _ height: CGFloat) -> some View {
        if v > 0 { color.frame(height: max(2, (height - 1) * v / peak)) }
    }
}
