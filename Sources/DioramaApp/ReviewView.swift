import AppKit
import DioramaCore
import SwiftUI

/// Rewrites held for approval (review mode): what Claude would see, and Approve / Reject.
/// Claude waits while a rewrite is here; when the time runs out it gets the original.
struct ReviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// For snapshots; otherwise the model's live list.
    var sample: [PendingReview]?

    var reviews: [PendingReview] { sample ?? model.pendingReviews }

    /// For snapshots.
    static var demo: PendingReview {
        PendingReview(
            id: "toolu_demo", sessionId: "ses_demo", sessionName: "docs heading demo", toolName: "WebFetch", toolInput: #"{"url":"https://example.com"}"#,
            stage: .result, originalText: "Example Domain\n\nThis domain is for use in documentation examples.",
            proposedText: "Morph Test Domain\n\nThis domain is for use in documentation examples.", explanation: "Renamed the heading as instructed.",
            rules: ["Rename domain heading"], createdAt: Date(), expiresAt: Date().addingTimeInterval(52))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Review rewrites").font(.title2.bold())
                Text("Claude is waiting for these tool results. Approve to send the rewrite; reject, or let the time run out, to send the original.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if reviews.isEmpty {
                        ContentUnavailableView("Nothing to review", systemImage: "checkmark.circle", description: Text("New rewrites from profiles with review mode on appear here."))
                            .padding(.top, 40)
                    }
                    ForEach(reviews) { r in ReviewCard(review: r, isFirst: r.id == reviews.first?.id) }
                }
                .padding(20)
            }
            Divider()
            HStack {
                if reviews.count > 1 {
                    Button("Reject All") { Task { for r in reviews { await model.resolveReview(r, approve: false) } } }
                    Button("Approve All") { Task { for r in reviews { await model.resolveReview(r, approve: true) } } }
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
        }
        .frame(width: 760, height: 680)
    }
}

private struct ReviewCard: View {
    @Environment(AppModel.self) private var model
    let review: PendingReview
    /// The oldest review answers the keyboard shortcuts (⌘↩ approve, ⌘⌫ reject).
    var isFirst = false
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: Fmt.toolIcon(review.toolName)).foregroundStyle(.secondary)
                Text(Fmt.toolName(review.toolName)).fontWeight(.medium)
                if let t = Fmt.toolTarget(review.toolName, review.toolInput) { Text(t).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                if review.stage == .page { Badge(text: "page", color: .teal) }
                Spacer()
                SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let left = max(0, Int(review.expiresAt.timeIntervalSince(ctx.date)))
                    Text("\(left) s").monospacedDigit().foregroundStyle(left <= 10 ? .orange : .secondary)
                        .help("When the time runs out, Claude gets the original")
                }
            }
            Text("In “\(review.sessionName)” · \(review.rules.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
            Text(review.explanation).font(.callout)
            ScrollView {
                DiffText(original: review.originalText, replacement: review.proposedText).padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Spacer()
                if isFirst { Text("⌘⌫ reject · ⌘↩ approve").font(.caption).foregroundStyle(.tertiary) }
                Button("Reject") { act(false) }.disabled(busy)
                    .keyboardShortcut(isFirst ? KeyboardShortcut(.delete, modifiers: .command) : nil)
                Button("Approve") { act(true) }.buttonStyle(.borderedProminent).disabled(busy)
                    .keyboardShortcut(isFirst ? KeyboardShortcut(.return, modifiers: .command) : nil)
            }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }

    func act(_ approve: Bool) {
        busy = true
        Task {
            await model.resolveReview(review, approve: approve)
            busy = false
        }
    }
}

/// Shown above every screen while rewrites wait for review.
struct ReviewBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.pendingReviews.isEmpty {
            HStack {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                Text("\(Fmt.plural(model.pendingReviews.count, "rewrite")) waiting for your review. Claude is paused until you answer.")
                Spacer()
                Button("Review…") { model.showReviews = true }.buttonStyle(.borderedProminent).tint(.orange)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.orange.opacity(0.12))
        }
    }
}
