import AppKit
import DioramaCore
import SwiftUI

/// Word-level diff rendered with highlighted insertions and deletions.
struct DiffText: View {
    let original: String
    let replacement: String

    var body: some View {
        let segs = TextDiff.diff(original, replacement)
        var text = AttributedString()
        for s in segs {
            var piece = AttributedString(s.text)
            switch s.op {
            case .equal: break
            case .insert:
                piece.backgroundColor = Color.green.opacity(0.28)
            case .delete:
                piece.backgroundColor = Color.red.opacity(0.25)
                piece.strikethroughStyle = .single
            }
            text += piece
        }
        return Text(text).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MonoBlock: View {
    let text: String
    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "(empty)" : text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
    }
}

struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18)).foregroundStyle(color).clipShape(Capsule())
    }
}

extension ToolResultHandling {
    var label: String {
        switch self {
        case .decidedRewritten: return "rewritten"
        case .decidedUnchanged: return "unchanged"
        case .decidedFailed: return "failed"
        case .replayedRewritten: return "replayed rewrite"
        case .replayedUnchanged: return "replayed"
        case .replayedFailed: return "replayed (failed)"
        case .clientModified: return "client-modified"
        case .skipped: return "skipped"
        }
    }

    var color: Color {
        switch self {
        case .decidedRewritten, .replayedRewritten: return .purple
        case .decidedFailed, .replayedFailed: return .red
        case .clientModified: return .orange
        default: return .secondary
        }
    }

    var isNewDecision: Bool { [.decidedRewritten, .decidedUnchanged, .decidedFailed, .clientModified].contains(self) }
}

extension DecisionOutcome {
    var color: Color {
        switch self {
        case .rewritten: return .purple
        case .failed: return .red
        case .unchanged: return .secondary
        }
    }
}

func formatMoney(_ d: Double?) -> String {
    guard let d else { return "—" }
    return d < 0.01 ? String(format: "$%.4f", d) : String(format: "$%.2f", d)
}

func formatMs(_ d: Double?) -> String {
    guard let d else { return "—" }
    return d >= 1000 ? String(format: "%.1fs", d / 1000) : "\(Int(d))ms"
}

func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

@MainActor
func chooseFolder(prompt: String = "Choose") -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = prompt
    return panel.runModal() == .OK ? panel.url?.path : nil
}

func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

/// Opens Terminal.app running `command` via a temporary `.command` script.
func openInTerminal(_ command: String) throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("diorama-launch", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let script = dir.appendingPathComponent("session-\(UUID().uuidString.prefix(8)).command")
    try "#!/bin/zsh -l\n\(command)\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    NSWorkspace.shared.open(script)
}
