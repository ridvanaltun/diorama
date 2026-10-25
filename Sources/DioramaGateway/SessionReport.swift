import DioramaCore
import DioramaStore
import Foundation

/// A session's audit trail as a document to keep or share: what was configured, what Diorama
/// changed (with diffs, rules, the rewrite agent's work and what Claude did next), and what it
/// left alone. Markdown, or self-contained HTML.
struct SessionReport {
    struct Change {
        var detail: DecisionDetail
        var original: String
        var replacement: String?
    }

    var session: SessionInfo
    var changes: [Change]
    var unchanged: [DecisionSummary]
    var notices: [SessionEvent]
    var rules: [RuleRef]
    var requests: Int
    var impacts: [String: DecisionImpact] = [:]
    var generatedAt = Date()

    static func build(sessionId: String, store: Store) throws -> SessionReport {
        guard let record = try store.session(id: sessionId) else { throw StoreError("no session \(sessionId)") }
        let info = try store.info(record)
        let decisions = try store.decisions(sessionId: sessionId).sorted { $0.createdAt < $1.createdAt }
        var changes: [Change] = []
        var unchanged: [DecisionSummary] = []
        var rules: [String: RuleRef] = [:]
        for d in decisions {
            for r in d.rules { rules[r.ruleHash] = r }
            guard d.outcome != .unchanged, let detail = try store.decisionDetail(toolUseId: d.toolUseId) else {
                unchanged.append(d.summary)
                continue
            }
            // Readable text, split the way the engine read it (hook-mode results are stored as JSON).
            let original = DioramaDaemon.readableSegments(d, via: record.via, store: store).joined(separator: "\n\n")
            let replacement = d.replacementBlob.map { blob -> String in
                var copy = d
                copy.originalBlob = blob
                return DioramaDaemon.readableSegments(copy, via: record.via, store: store).joined(separator: "\n\n")
            }
            changes.append(Change(detail: detail, original: original, replacement: replacement))
        }
        let notices = try store.events(sessionId: sessionId).filter { $0.kind == .anomaly || $0.kind == .rewriteFailed || $0.kind == .warning }
        let requests = try store.exchanges(sessionId: sessionId).filter { $0.method == "POST" && $0.path == "/v1/messages" }.count
        let impacts = Dictionary(((try? DioramaDaemon.impact(sessionId: sessionId, store: store)) ?? []).map { ($0.toolUseId, $0) }, uniquingKeysWith: { a, _ in a })
        return SessionReport(session: info, changes: changes, unchanged: unchanged, notices: notices, rules: rules.values.sorted { $0.name < $1.name },
                             requests: requests, impacts: impacts)
    }

    // MARK: Shared pieces

    /// `code` marks ids as Markdown code; HTML gets plain text.
    func steering(code: Bool = true) -> String {
        let q = code ? "`" : ""
        var parts: [String] = []
        if let p = session.profileName { parts.append("profile “\(p)” v\(session.profileVersionNumber ?? 0) (\(q)\(session.profileVersionId ?? "")\(q))") }
        if let p = session.prompt { parts.append("session prompt for \(p.tools.joined(separator: ", ")): “\(p.text)”") }
        return parts.isEmpty ? "none (recorded only)" : parts.joined(separator: "; ")
    }

    func title(_ d: DecisionSummary) -> String {
        let tool = d.toolName ?? "tool"
        let stage = d.toolUseId.hasPrefix("page:") ? " page (before summarization)" : d.toolUseId.hasPrefix("input:") ? " input (before the call)" : " result"
        return tool + stage + (Self.target(d.toolName, d.toolInput).map { " — \($0)" } ?? "")
    }

    static func target(_ tool: String?, _ input: String?) -> String? {
        guard let input, let obj = try? JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any] else { return nil }
        for key in ["url", "query", "file_path", "command", "pattern"] {
            if let v = obj[key] as? String, !v.isEmpty { return v.count > 120 ? String(v.prefix(120)) + "…" : v }
        }
        return nil
    }

    /// Local, readable time (the exact ISO times stay in the JSON records).
    static func time(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .standard) }

    func mode(code: Bool = true) -> String {
        session.isHook ? "hook mode (Claude desktop / IDE: tool results only)" : (code ? "gateway (`diorama run`)" : "gateway (diorama run)")
    }

    /// "“text” — calls WebFetch, Read", whichever parts exist.
    static func followUp(_ f: AssistantSummary) -> String {
        [f.text.isEmpty ? nil : "“\(clip(f.text, 400))”", f.toolUses.isEmpty ? nil : "calls " + f.toolUses.map(\.name).joined(separator: ", ")]
            .compactMap { $0 }.joined(separator: " — ")
    }

    // MARK: Markdown

    func markdown() -> String {
        let s = session
        var md = "# Diorama session report: \(s.name)\n\n"
        md += "- Session: `\(s.id)` — \(s.status.rawValue), \(mode())\n"
        md += "- Folder: `\(s.cwd)`\n"
        md += "- Started: \(Self.time(s.createdAt))" + (s.endedAt.map { ", ended \(Self.time($0))" } ?? "") + "\n"
        md += "- Steering: \(steering())\n"
        if s.lockdown != .none { md += "- Lockdown: \(s.lockdown.rawValue)\n" }
        if !s.flags.isEmpty { md += "- Flags: \(s.flags.joined(separator: ", "))\n" }
        if let tags = s.tags, !tags.isEmpty { md += "- Tags: \(tags.joined(separator: ", "))\n" }
        md += "- Generated: \(Self.time(generatedAt)) by Diorama \(DioramaVersion.current) (rewrite prompt \(DioramaVersion.rewritePromptVersion))\n\n"
        if let notes = s.notes, !notes.isEmpty { md += "## Notes\n\n\(notes)\n\n" }
        md += "## Summary\n\n"
        if !s.isHook { md += "- Model requests: \(requests)\n" }
        md += "- Tool results decided: \(s.stats.toolResults) — \(s.stats.rewrites) rewritten, \(s.stats.failures) failed, \(unchanged.count) left unchanged\n"
        md += String(format: "- Rewrite-agent cost: $%.4f\n", s.stats.rewriteCostUSD)
        if !impacts.isEmpty {
            md += "- Rewrites Claude used (heuristic): \(impacts.values.filter { $0.signals.contains(.used) }.count) of \(impacts.count)\n"
        }
        if !rules.isEmpty { md += "- Rules that applied: " + rules.map { "\($0.name) (`\($0.ruleHash)`)" }.joined(separator: ", ") + "\n" }
        if !notices.isEmpty {
            md += "\n## Notices\n\n" + notices.map { "- \(Self.time($0.createdAt)) — \($0.kind.rawValue): \($0.message)" }.joined(separator: "\n") + "\n"
        }
        md += "\n## What Diorama changed\n\n"
        if changes.isEmpty { md += "Nothing: every tool result reached Claude unchanged.\n" }
        for (i, c) in changes.enumerated() {
            let d = c.detail.summary
            md += "### \(i + 1). \(title(d))\n\n"
            md += "- \(Self.time(d.createdAt)) · **\(d.outcome.rawValue)** · `\(d.toolUseId)`\n"
            md += "- Why: \(d.reason)\n"
            if !d.rules.isEmpty { md += "- Rules: " + d.rules.map(\.name).joined(separator: ", ") + "\n" }
            for a in c.detail.attempts {
                md += "- Rewrite agent: \(a.status.rawValue), \(a.modelServed ?? a.modelRequested), \(Int(a.latencyMs)) ms" + (a.costUSD.map { String(format: ", $%.4f", $0) } ?? "") + "\n"
            }
            if let r = c.replacement {
                md += "\nChange (word level: ~~removed~~ **added**):\n\n> " + Self.markdownDiff(c.original, r).replacingOccurrences(of: "\n", with: "\n> ") + "\n"
            }
            if let f = c.detail.followUp, !(f.text.isEmpty && f.toolUses.isEmpty) {
                md += "\nWhat Claude did next: " + Self.followUp(f) + "\n"
            }
            if let i = impacts[c.detail.summary.toolUseId] {
                md += "\nDid Claude use it (heuristic): **\(i.label)**" + (i.evidence.isEmpty ? "" : " — " + i.evidence.joined(separator: "; ")) + "\n"
            }
            md += "\n"
        }
        if !unchanged.isEmpty {
            md += "## Left unchanged\n\n| Time | Tool | Target | Reason |\n|---|---|---|---|\n"
            for d in unchanged {
                md += "| \(Self.time(d.createdAt)) | \(d.toolName ?? "") | \(Self.cell(Self.target(d.toolName, d.toolInput) ?? "")) | \(Self.cell(d.reason)) |\n"
            }
        }
        md += "\n---\nRecords are local to this Mac. Original tool results may contain private data; review before sharing.\n"
        return md
    }

    static func markdownDiff(_ a: String, _ b: String) -> String {
        TextDiff.diff(a, b).map { seg in
            let t = seg.text
            switch seg.op {
            case .equal: return t
            case .delete: return t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? t : "~~\(t)~~"
            case .insert: return t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? t : "**\(t)**"
            }
        }.joined()
    }

    static func cell(_ s: String) -> String { clip(s, 140).replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ") }
    static func clip(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n)) + "…" : s }

    // MARK: HTML

    func html() -> String {
        let s = session
        func e(_ t: String) -> String { Self.escape(t) }
        var h = """
            <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
            <title>Diorama session report: \(e(s.name))</title>
            <style>
            :root{--bg:#fff;--fg:#1d1d1f;--muted:#6e6e73;--card:#f5f5f7;--line:#e5e5ea;--del:#ffd7d5;--ins:#d4f5dc;--accent:#7a3cc4}
            @media (prefers-color-scheme:dark){:root{--bg:#1c1c1e;--fg:#f2f2f7;--muted:#98989d;--card:#2c2c2e;--line:#3a3a3c;--del:#5c2b29;--ins:#1f4d2c;--accent:#c39bff}}
            body{background:var(--bg);color:var(--fg);font:15px/1.5 -apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif;max-width:920px;margin:0 auto;padding:32px 20px}
            h1{font-size:26px;margin:0 0 4px}h2{font-size:19px;margin:32px 0 10px}h3{font-size:16px;margin:0 0 6px}
            .muted{color:var(--muted)}.meta{display:grid;grid-template-columns:max-content 1fr;gap:4px 14px;margin:16px 0}
            .tiles{display:flex;gap:10px;flex-wrap:wrap}.tile{background:var(--card);border-radius:10px;padding:8px 14px}.tile b{display:block;font-size:18px}
            .card{background:var(--card);border-radius:12px;padding:14px 16px;margin:12px 0}
            .badge{display:inline-block;border-radius:6px;padding:1px 7px;font-size:12px;font-weight:600;background:var(--line)}
            .rewritten{background:#efe3ff;color:#6b2fb5}.failed{background:#ffe1df;color:#b3261e}
            @media (prefers-color-scheme:dark){.rewritten{background:#3d2a57;color:#d9c2ff}.failed{background:#5c2b29;color:#ffb4ab}}
            .diff{font:13px/1.55 ui-monospace,Menlo,monospace;white-space:pre-wrap;background:var(--bg);border:1px solid var(--line);border-radius:8px;padding:10px;margin-top:8px}
            del{background:var(--del);text-decoration:line-through}ins{background:var(--ins);text-decoration:none}
            table{border-collapse:collapse;width:100%;font-size:13px}td,th{text-align:left;padding:6px 8px;border-bottom:1px solid var(--line);vertical-align:top}
            code{font:12px ui-monospace,Menlo,monospace}.notice{border-left:3px solid #e8a200;padding-left:10px;margin:6px 0}
            </style></head><body>
            <h1>\(e(s.name))</h1><div class="muted">Diorama session report · generated \(e(Self.time(generatedAt))) by Diorama \(e(DioramaVersion.current))</div>
            <div class="meta">
            <span class="muted">Session</span><span><code>\(e(s.id))</code> — \(e(s.status.rawValue)), \(e(mode(code: false)))</span>
            <span class="muted">Folder</span><span><code>\(e(s.cwd))</code></span>
            <span class="muted">Started</span><span>\(e(Self.time(s.createdAt)))\(s.endedAt.map { ", ended " + e(Self.time($0)) } ?? "")</span>
            <span class="muted">Steering</span><span>\(e(steering(code: false)))</span>
            \(s.flags.isEmpty ? "" : "<span class=\"muted\">Flags</span><span>\(e(s.flags.joined(separator: ", ")))</span>")
            \((s.tags ?? []).isEmpty ? "" : "<span class=\"muted\">Tags</span><span>\(e((s.tags ?? []).joined(separator: ", ")))</span>")
            </div>
            \((s.notes ?? "").isEmpty ? "" : "<h2>Notes</h2><p style=\"white-space:pre-wrap\">\(e(s.notes ?? ""))</p>")
            <div class="tiles">
            \(s.isHook ? "" : "<div class=\"tile\"><b>\(requests)</b><span class=\"muted\">requests</span></div>")
            <div class="tile"><b>\(s.stats.toolResults)</b><span class="muted">tool results</span></div>
            <div class="tile"><b>\(s.stats.rewrites)</b><span class="muted">rewritten</span></div>
            <div class="tile"><b>\(s.stats.failures)</b><span class="muted">failed</span></div>
            <div class="tile"><b>\(String(format: "$%.4f", s.stats.rewriteCostUSD))</b><span class="muted">rewrite cost</span></div>
            </div>
            """
        if !notices.isEmpty {
            h += "<h2>Notices</h2>" + notices.map { "<div class=\"notice\"><span class=\"muted\">\(e(Self.time($0.createdAt)))</span> \(e($0.message))</div>" }.joined()
        }
        h += "<h2>What Diorama changed</h2>"
        if changes.isEmpty { h += "<p class=\"muted\">Nothing: every tool result reached Claude unchanged.</p>" }
        for c in changes {
            let d = c.detail.summary
            h += "<div class=\"card\"><h3>\(e(title(d)))</h3>"
            h += "<div><span class=\"badge \(d.outcome.rawValue)\">\(e(d.outcome.rawValue))</span> <span class=\"muted\">\(e(Self.time(d.createdAt))) · <code>\(e(d.toolUseId))</code></span></div>"
            h += "<p>\(e(d.reason))</p>"
            if !d.rules.isEmpty { h += "<div class=\"muted\">Rules: \(e(d.rules.map(\.name).joined(separator: ", ")))</div>" }
            for a in c.detail.attempts {
                h += "<div class=\"muted\">Rewrite agent: \(e(a.status.rawValue)), \(e(a.modelServed ?? a.modelRequested)), \(Int(a.latencyMs)) ms\(a.costUSD.map { String(format: ", $%.4f", $0) } ?? "")</div>"
            }
            if let r = c.replacement { h += "<div class=\"diff\">\(Self.htmlDiff(c.original, r))</div>" }
            if let f = c.detail.followUp, !(f.text.isEmpty && f.toolUses.isEmpty) {
                h += "<p class=\"muted\">What Claude did next: \(e(Self.followUp(f)))</p>"
            }
            if let i = impacts[c.detail.summary.toolUseId] {
                h += "<p class=\"muted\">Did Claude use it (heuristic): <b>\(e(i.label))</b>\(i.evidence.isEmpty ? "" : " — " + e(i.evidence.joined(separator: "; ")))</p>"
            }
            h += "</div>"
        }
        if !unchanged.isEmpty {
            h += "<h2>Left unchanged</h2><table><tr><th>Time</th><th>Tool</th><th>Target</th><th>Reason</th></tr>"
            for d in unchanged {
                h += "<tr><td class=\"muted\">\(e(Self.time(d.createdAt)))</td><td>\(e(d.toolName ?? ""))</td><td>\(e(Self.clip(Self.target(d.toolName, d.toolInput) ?? "", 140)))</td><td>\(e(Self.clip(d.reason, 160)))</td></tr>"
            }
            h += "</table>"
        }
        h += "<p class=\"muted\" style=\"margin-top:28px\">Records are local to this Mac. Original tool results may contain private data; review before sharing.</p></body></html>"
        return h
    }

    static func htmlDiff(_ a: String, _ b: String) -> String {
        TextDiff.diff(a, b).map { seg in
            switch seg.op {
            case .equal: escape(seg.text)
            case .delete: "<del>\(escape(seg.text))</del>"
            case .insert: "<ins>\(escape(seg.text))</ins>"
            }
        }.joined()
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
