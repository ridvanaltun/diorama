import DioramaCore
import Foundation

/// A Model Context Protocol server (`diorama mcp`) that lets an AI assistant inspect and steer
/// Diorama: read sessions and audit records, manage profiles and hooks, and run experiments.
/// It speaks JSON-RPC over stdio, one message per line, and calls the daemon's control API.
public actor MCPServer {
    public struct Tool: Sendable {
        public var name: String
        public var description: String
        public var schema: [String: any Sendable]
        public var readOnly: Bool
        public var destructive = false
        public var openWorld = false
        public var run: @Sendable (MCPServer, MCPArgs) async throws -> String
    }

    struct ToolError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    let connect: @Sendable () async throws -> ControlClient
    let cliPath: String
    nonisolated let readOnly: Bool
    private var client: ControlClient?

    /// `cliPath` is the `diorama` executable that hook installs point at.
    public init(cliPath: String, readOnly: Bool = false, connect: @escaping @Sendable () async throws -> ControlClient) {
        self.cliPath = cliPath
        self.readOnly = readOnly
        self.connect = connect
    }

    func daemon() async throws -> ControlClient {
        if let client { return client }
        let c = try await connect()
        client = c
        return c
    }

    public var tools: [Tool] { MCPTools.all.filter { !readOnly || $0.readOnly } }

    public static let instructions = """
        Diorama sits between Claude Code and the model: it can rewrite tool results (web pages, files, \
        command output) according to profiles and session prompts, records every decision, and runs A/B \
        experiments comparing an unmodified control with steered variants. Experiment runs launch real \
        Claude Code sessions and cost money: always call estimate_experiment_run first, show the user the \
        estimate, and call start_experiment_run only after they approve it. Report experiment results as \
        observations under the stated caveats, never as proof of cause.
        """

    // MARK: JSON-RPC

    /// Handles one incoming line; returns the response line, or nil for notifications.
    public func handle(_ line: String) async -> String? {
        guard let data = line.data(using: .utf8), let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "parse error"]])
        }
        let id = msg["id"]
        guard let method = msg["method"] as? String else { return nil }  // a response from the client; ignore
        let params = msg["params"] as? [String: Any] ?? [:]
        guard let id else { return nil }  // notification (e.g. notifications/initialized)
        do {
            let result = try await dispatch(method, params)
            return encode(["jsonrpc": "2.0", "id": id, "result": result])
        } catch let e as RPCError {
            return encode(["jsonrpc": "2.0", "id": id, "error": ["code": e.code, "message": e.message]])
        } catch {
            return encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32603, "message": String(describing: error)]])
        }
    }

    struct RPCError: Error {
        let code: Int
        let message: String
    }

    func dispatch(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            return [
                "protocolVersion": Self.protocolVersions.contains(requested) ? requested : Self.protocolVersions[1],
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "diorama", "title": "Diorama", "version": DioramaVersion.current],
                "instructions": Self.instructions,
            ]
        case "ping":
            return [:]
        case "tools/list":
            return ["tools": tools.map { t -> [String: Any] in
                [
                    "name": t.name, "description": t.description, "inputSchema": t.schema,
                    "annotations": ["readOnlyHint": t.readOnly, "destructiveHint": t.destructive, "openWorldHint": t.openWorld],
                ]
            }]
        case "tools/call":
            guard let name = params["name"] as? String, let tool = tools.first(where: { $0.name == name }) else {
                throw RPCError(code: -32602, message: "unknown tool: \(params["name"] as? String ?? "")")
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                let text = try await tool.run(self, MCPArgs(values: args))
                return ["content": [["type": "text", "text": text]], "isError": false]
            } catch {
                // Tool failures go back to the model as results it can read and correct.
                let message = (error as? ClientError)?.message ?? (error as? ToolError)?.description ?? String(describing: error)
                return ["content": [["type": "text", "text": "Error: \(message)"]], "isError": true]
            }
        default:
            throw RPCError(code: -32601, message: "method not found: \(method)")
        }
    }

    func encode(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Serves stdin/stdout until stdin closes. Requests are handled one at a time, in order.
    public func serve() async {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let reply = await handle(line) {
                FileHandle.standardOutput.write(Data((reply + "\n").utf8))
            }
        }
    }
}

// MARK: - Tools

/// A tool call's arguments (plain JSON values, read-only once parsed).
public struct MCPArgs: @unchecked Sendable {
    let values: [String: Any]
    subscript(key: String) -> Any? { values[key] }
}

enum MCPTools {
    typealias Args = MCPArgs

    static func schema(_ properties: [String: [String: any Sendable]] = [:], required: [String] = []) -> [String: any Sendable] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }

    static func string(_ description: String) -> [String: any Sendable] { ["type": "string", "description": description] }

    static func arg(_ args: Args, _ key: String) throws -> String {
        guard let v = args[key] as? String, !v.isEmpty else { throw MCPServer.ToolError("missing argument '\(key)'") }
        return v
    }

    /// Decodes a JSON object argument into a Diorama type (same format as the CLI's JSON files).
    static func object<T: Decodable>(_ args: Args, _ key: String, as: T.Type) throws -> T {
        guard let v = args[key], JSONSerialization.isValidJSONObject(v) else { throw MCPServer.ToolError("argument '\(key)' must be a JSON object") }
        let data = try JSONSerialization.data(withJSONObject: v)
        do {
            return try DioramaCoding.decoder.decode(T.self, from: data)
        } catch {
            throw MCPServer.ToolError("argument '\(key)' is not a valid \(T.self): \(error)")
        }
    }

    static func json<T: Encodable>(_ v: T) throws -> String { String(decoding: try DioramaCoding.prettyEncoder.encode(v), as: UTF8.self) }

    static func clip(_ s: String, _ n: Int = 6000) -> String { s.count > n ? String(s.prefix(n)) + "\n… [\(s.count - n) more characters]" : s }

    static let all: [MCPServer.Tool] = [
        // Read-only
        .init(name: "diorama_status", description: "Daemon health and diagnostics: Claude Code found, rewrite API key configured, database, storage.", schema: schema(), readOnly: true) { s, _ in
            let c = try await s.daemon()
            let health = try await c.health()
            let doctor = try await c.doctor()
            let checks = doctor.checks.map { "- [\($0.status.rawValue)] \($0.name): \($0.detail)" }.joined(separator: "\n")
            let spend = try await c.spend()
            let budget = "Rewrite spending today: $\(String(format: "%.4f", spend.todayUSD))" + (spend.dailyBudgetUSD.map { String(format: " of a $%.2f daily cap", $0) + (spend.isOverBudget ? " (used up: rewrites are paused)" : "") } ?? " (no daily cap)")
            return budget + "\n" + "Diorama \(health.version), daemon pid \(health.pid) on 127.0.0.1:\(health.port), \(health.activeSessions) active session(s), data in \(health.dataDirectory)\n\(checks)"
        },
        .init(
            name: "list_sessions", description: "Recent Diorama sessions with their profile, mode (gateway or hook) and counts of tool results, rewrites and failures.",
            schema: schema(["kind": ["type": "string", "enum": ["interactive", "trial"], "description": "Only this kind (default: all)."],
                            "tag": string("Only sessions with this tag (optional)."),
                            "limit": ["type": "integer", "minimum": 1, "maximum": 200, "description": "Default 20."]]),
            readOnly: true
        ) { s, a in
            let kind = (a["kind"] as? String).flatMap(SessionKind.init(rawValue:))
            let rows = try await s.daemon().sessions(kind: kind, tag: (a["tag"] as? String).flatMap { $0.isEmpty ? nil : $0 }, limit: (a["limit"] as? Int) ?? 20)
            guard !rows.isEmpty else { return "No sessions yet." }
            return rows.map { r in
                let mode = r.isHook ? "hook" : "gateway"
                let steer = r.profileName.map { "profile \($0) v\(r.profileVersionNumber ?? 0)" } ?? (r.prompt != nil ? "session prompt" : "no rules")
                return "- \(r.id) “\(r.name)” [\(r.status.rawValue), \(r.kind.rawValue), \(mode)] \(steer); \(r.stats.toolResults) results, \(r.stats.rewrites) rewritten, \(r.stats.failures) failed; cwd \(r.cwd); started \(DateFormatting.string(r.createdAt))"
            }.joined(separator: "\n")
        },
        .init(
            name: "get_session", description: "One session's configuration and its decided tool results in order (tool, target, outcome, reason), plus anomalies. Use get_decision for one result's full audit record.",
            schema: schema(["session_id": string("Session id (ses_…).")], required: ["session_id"]), readOnly: true
        ) { s, a in
            let t = try await s.daemon().timeline(try arg(a, "session_id"))
            let info = t.session
            var out = ["Session \(info.id) “\(info.name)” — \(info.status.rawValue), \(info.isHook ? "hook mode (tool results only)" : "gateway"), cwd \(info.cwd)"]
            if let p = info.profileName { out.append("Profile: \(p) v\(info.profileVersionNumber ?? 0)") }
            if let p = info.prompt { out.append("Session prompt (\(p.tools.joined(separator: ","))): \(p.text)") }
            if let tags = info.tags, !tags.isEmpty { out.append("Tags: \(tags.joined(separator: ", "))") }
            if let notes = info.notes, !notes.isEmpty { out.append("Notes:\n\(notes)") }
            if !info.isHook { out.append("Requests: \(info.stats.exchanges)") }
            out.append("Tool results: \(info.stats.toolResults), rewritten \(info.stats.rewrites), failed \(info.stats.failures), rewrite cost $\(String(format: "%.4f", info.stats.rewriteCostUSD))")
            let notices = t.events.filter { $0.kind == .anomaly || $0.kind == .rewriteFailed }
            if !notices.isEmpty { out.append("Notices:\n" + notices.map { "- \($0.message)" }.joined(separator: "\n")) }
            out.append("Decisions:")
            for d in t.decisions.sorted(by: { $0.createdAt < $1.createdAt }) {
                out.append("- \(d.toolUseId) \(d.toolName ?? "tool")\(target(d.toolName, d.toolInput).map { " (\($0))" } ?? ""): \(d.outcome.rawValue) — \(d.reason)")
            }
            return out.joined(separator: "\n")
        },
        .init(
            name: "get_decision", description: "The full audit record for one tool result: original and rewritten text, rules and instructions, rewrite-agent attempts, and what Claude did next.",
            schema: schema(["tool_use_id": string("The tool_use_id from get_session.")], required: ["tool_use_id"]), readOnly: true
        ) { s, a in
            let d = try await s.daemon().decision(try arg(a, "tool_use_id"))
            var out = ["\(d.summary.toolName ?? "tool") \(d.summary.toolUseId): \(d.summary.outcome.rawValue) — \(d.summary.reason)"]
            if let i = d.toolInput { out.append("Input: \(clip(i, 500))") }
            out.append("Rules: " + (d.summary.rules.isEmpty ? "none" : d.summary.rules.map(\.name).joined(separator: ", ")))
            if !d.instructions.isEmpty { out.append("Instructions:\n" + d.instructions.map { "- \($0)" }.joined(separator: "\n")) }
            out.append("Original:\n" + clip(d.originalText))
            if let r = d.replacementText { out.append("What Claude saw instead:\n" + clip(r)) }
            for at in d.attempts {
                out.append("Attempt \(at.status.rawValue) with \(at.modelServed ?? at.modelRequested), \(Int(at.latencyMs)) ms\(at.costUSD.map { String(format: ", $%.4f", $0) } ?? ""): \(at.explanation ?? at.error ?? "")")
                for e in at.edits { out.append("  edit: “\(e.find)” → “\(e.replace)” (\(e.rationale))") }
            }
            if let f = d.followUp {
                out.append("Claude next: " + clip(f.text, 1500) + (f.toolUses.isEmpty ? "" : " | calls " + f.toolUses.map(\.name).joined(separator: ", ")))
            }
            return out.joined(separator: "\n")
        },
        .init(
            name: "search",
            description: "Full-text search across all sessions: tool results (original and rewritten), tool inputs such as URLs and queries, rewrite reasons, and Claude's replies. All words must match. Matched words are marked ⟦like this⟧. Use get_decision or get_session with the returned ids for details.",
            schema: schema([
                "query": string("Words to find."), "rewritten_only": ["type": "boolean", "description": "Only results Diorama rewrote."],
                "session_id": string("Only this session."), "limit": ["type": "integer", "minimum": 1, "maximum": 100, "description": "Default 20."],
            ], required: ["query"]),
            readOnly: true
        ) { s, a in
            let hits = try await s.daemon().search(try arg(a, "query"), rewrittenOnly: a["rewritten_only"] as? Bool ?? false, sessionId: a["session_id"] as? String,
                                                   limit: (a["limit"] as? Int) ?? 20)
            guard !hits.isEmpty else { return "No matches." }
            return hits.map { h in
                let what = h.kind == .reply ? "Claude's reply (exchange \(h.ref))" : "\(h.toolName ?? "tool") \(h.outcome?.rawValue ?? "") — tool_use_id \(h.ref)"
                return "- \(h.sessionName) (\(h.sessionId)), \(DateFormatting.string(h.createdAt)): \(what)\n  \(h.snippet.replacingOccurrences(of: "\n", with: " "))"
            }.joined(separator: "\n")
        },
        .init(
            name: "get_session_report",
            description: "A session's audit trail as Markdown: configuration, summary, notices, every change Diorama made (word diff, rules, rewrite agent, what Claude did next), and what it left unchanged. Good for summarizing or sharing a session.",
            schema: schema(["session_id": string("Session id (ses_…).")], required: ["session_id"]), readOnly: true
        ) { s, a in
            clip(try await s.daemon().sessionReport(try arg(a, "session_id"), format: "md"), 20000)
        },
        .init(name: "list_profiles", description: "Profiles: versioned sets of rules that say which tool results to rewrite and how.", schema: schema(), readOnly: true) { s, _ in
            let ps = try await s.daemon().profiles()
            guard !ps.isEmpty else { return "No profiles yet. See list_rule_templates and create_profile." }
            return ps.map { "- \($0.id) “\($0.name)” v\($0.currentVersionNumber), \($0.ruleCount) rule(s)" }.joined(separator: "\n")
        },
        .init(
            name: "get_profile", description: "A profile's current version as JSON (the same format create_profile and update_profile accept).",
            schema: schema(["profile": string("Profile name or id.")], required: ["profile"]), readOnly: true
        ) { s, a in
            let d = try await s.daemon().profile(try arg(a, "profile"))
            return "Profile \(d.current.profileId), version \(d.current.number) (\(d.current.id)):\n" + (try json(d.current.profile))
        },
        .init(
            name: "get_spend_history",
            description: "Rewrite-agent spending per day (sessions, experiment trials, playground/what-if previews, calls) and per profile, for the last N days.",
            schema: schema(["days": ["type": "integer", "minimum": 1, "maximum": 366, "description": "Days to cover, today included (default 30)."]]),
            readOnly: true
        ) { s, a in
            let days = (a["days"] as? Int) ?? (a["days"] as? Double).map { Int($0) } ?? 30
            return SpendHistoryText.render(try await s.daemon().spendHistory(days: days))
        },
        .init(
            name: "compare_profile_versions",
            description: "What changed between two versions of a profile: name, description, defaults, and per rule whether it was added, removed, changed (which fields, old → new) or moved.",
            schema: schema(["profile": string("Profile name or id."), "from": ["type": "integer", "description": "Older version number (default: the one before 'to')."],
                            "to": ["type": "integer", "description": "Newer version number (default: the current one)."]], required: ["profile"]),
            readOnly: true
        ) { s, a in
            func int(_ k: String) -> Int? { (a[k] as? Int) ?? (a[k] as? Double).map { Int($0) } }
            let detail = try await s.daemon().profile(try arg(a, "profile"))
            let (x, y): (ProfileVersionInfo, ProfileVersionInfo)
            do { (x, y) = try ProfileComparison.versions(detail, from: int("from"), to: int("to")) } catch { throw MCPServer.ToolError("\(error)") }
            return ProfileComparison.compare(x.profile, y.profile).text(from: "v\(x.number)", to: "v\(y.number)")
        },
        .init(
            name: "list_pending_reviews",
            description: "Rewrites waiting for the user's approval (profiles with review mode on). Read-only: only the user approves or rejects rewrites, in the Diorama app or with `diorama review`.",
            schema: schema(), readOnly: true
        ) { s, _ in
            let pending = try await s.daemon().pendingReviews()
            guard !pending.isEmpty else { return "Nothing is waiting for review." }
            return pending.map { r in
                "- \(r.id): \(r.toolName) in “\(r.sessionName)”, \(max(0, Int(r.expiresAt.timeIntervalSinceNow))) s left — \(r.explanation)"
            }.joined(separator: "\n") + "\nAsk the user to approve or reject these in Diorama."
        },
        .init(
            name: "get_rule_stats",
            description: "How a profile's rules have been used: per rule, how often it matched, how many of those results were rewritten or left unchanged, classifier answers and cost. Rules that never matched are listed too. Experiment trials are left out unless include_trials is true.",
            schema: schema(["profile": string("Profile name or id."), "days": ["type": "integer", "description": "Days to look back (default 30, 0 = all time)."],
                            "include_trials": ["type": "boolean", "description": "Include experiment trials."]], required: ["profile"]),
            readOnly: true
        ) { s, a in
            let days = (a["days"] as? Int) ?? (a["days"] as? Double).map { Int($0) } ?? 30
            return try await s.daemon().ruleStats(try arg(a, "profile"), days: days, includeTrials: a["include_trials"] as? Bool ?? false).text
        },
        .init(name: "list_rule_templates", description: "Starting-point profiles that show the rule format (tools, input patterns, instructions, stage).", schema: schema(), readOnly: true) { s, _ in
            try json(try await s.daemon().templates())
        },
        .init(name: "list_experiments", description: "Experiments and their runs (status, trials done).", schema: schema(), readOnly: true) { s, _ in
            let es = try await s.daemon().experiments()
            guard !es.isEmpty else { return "No experiments yet." }
            return es.map { e in
                let runs = e.runs.map { "  - run \($0.id): \($0.status.rawValue), \($0.trialsDone)/\($0.trialsTotal) trials, \(DateFormatting.string($0.createdAt))" }
                return (["- \(e.id) “\(e.name)”: \(e.definition.variants.count) variants × \(e.definition.trialsPerVariant) trials; task: \(clip(e.definition.task, 200))"] + runs).joined(separator: "\n")
            }.joined(separator: "\n")
        },
        .init(
            name: "get_run_report",
            description: "An experiment run's report (Markdown): facts per variant, differences vs the control with 95% intervals, heuristic signals, caveats, and every trial. Give experiment_id instead of run_id to pool all its completed runs.",
            schema: schema(["run_id": string("Run id (run_…)."), "experiment_id": string("Pool all completed runs of this experiment instead.")]), readOnly: true
        ) { s, a in
            if let exp = a["experiment_id"] as? String, !exp.isEmpty {
                return clip(try await s.daemon().pooledReport(experimentId: exp, format: "md"), 20000)
            }
            return clip(try await s.daemon().report(try arg(a, "run_id"), format: "md"), 20000)
        },
        .init(
            name: "get_hook_status", description: "Whether a project folder has Diorama's Claude Code hook (hook mode, used by the Claude desktop app and IDEs), and its configuration.",
            schema: schema(["folder": string("Absolute path of the project folder.")], required: ["folder"]), readOnly: true
        ) { _, a in
            let url = HookInstaller.projectSettings(try arg(a, "folder"))
            guard let command = HookInstaller.installedCommand(settings: url) else { return "No Diorama hook in \(url.path)" }
            return "Diorama hook installed in \(url.path):\n\(command)"
        },

        MCPServer.Tool(
            name: "test_rules",
            description: "Try rules on a past tool result or on text, without a session: which rules match and why the others don't. With rewrite=true, also runs the rewrite agent once (a small cost) and returns what Claude would see. Nothing is recorded. Use it to iterate on a profile before saving it.",
            schema: schema([
                "profile": string("Saved profile name or id."),
                "profile_draft": ["type": "object", "description": "An unsaved profile to test instead ({name, rules: [...]})."],
                "prompt": string("A session prompt to test as well."),
                "tool_use_id": string("A past tool result to test on (from get_session)."),
                "text": string("Text to test on, instead of a past result."),
                "tool_name": string("The tool the text comes from (default WebFetch)."),
                "tool_input": ["type": "object", "description": "The tool input (rules can match on its fields), e.g. {\"url\": \"https://…\"}."],
                "rewrite": ["type": "boolean", "description": "Also run the rewrite agent (default false)."],
            ]),
            readOnly: true, openWorld: true
        ) { s, a in
            var req = PlaygroundRequest(
                profileRef: a["profile"] as? String, prompt: (a["prompt"] as? String).flatMap { $0.isEmpty ? nil : SessionPrompt(text: $0, tools: ["*"]) },
                toolUseId: a["tool_use_id"] as? String, text: a["text"] as? String, toolName: a["tool_name"] as? String, rewrite: a["rewrite"] as? Bool ?? false)
            if a["profile_draft"] != nil { req.profile = try object(a, "profile_draft", as: Profile.self) }
            if let input = a["tool_input"], JSONSerialization.isValidJSONObject(input) {
                req.toolInput = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
            }
            if req.rewrite, s.readOnly { throw MCPServer.ToolError("this server is read-only: rewrite=true calls the paid rewrite agent; use rewrite=false") }
            let r = try await s.daemon().playground(req)
            var out = ["\(r.toolName) \(r.stage.rawValue), \(r.originalText.count) characters"]
            out += r.checks.map { "- \($0.matches ? "MATCH" : "no match") \($0.name): \($0.reason)" }
            if let note = r.note { out.append(note) }
            if let rw = r.rewrite {
                out.append("Rewrite \(rw.status.rawValue) with \(rw.model), \(Int(rw.latencyMs)) ms\(rw.costUSD.map { String(format: ", $%.4f", $0) } ?? ""): \(rw.explanation ?? rw.error ?? "")")
                out += rw.edits.map { "  edit: “\($0.find)” → “\($0.replace)”" }
                if let t = rw.replacementText { out.append("What Claude would see:\n" + clip(t)) }
            } else {
                out.append("Content:\n" + clip(r.originalText, 2000))
            }
            return out.joined(separator: "\n")
        },

        MCPServer.Tool(
            name: "what_if_replay",
            description: "Re-run a session's recorded tool results through other rules (a saved profile, a specific version, an unsaved draft, or a prompt) and compare with what the session did. rewrite=false (default) only checks which rules match and estimates the cost, for free; rewrite=true calls the rewrite agent for each matching result (at most max_rewrites, default 25), which costs money: show the estimate to the user first. Nothing is recorded.",
            schema: schema([
                "session_id": string("Session id (ses_…)."), "profile": string("Saved profile name or id (current version)."),
                "profile_version_id": string("A specific saved version (pv_…), e.g. from get_profile."),
                "profile_draft": ["type": "object", "description": "An unsaved profile ({name, rules: [...]})."],
                "prompt": string("A session prompt to add."), "rewrite": ["type": "boolean", "description": "Run the rewrite agent (default false)."],
                "max_rewrites": ["type": "integer", "minimum": 0, "maximum": 60],
            ], required: ["session_id"]),
            readOnly: true, openWorld: true
        ) { s, a in
            var req = WhatIfRequest(
                sessionId: try arg(a, "session_id"), profileRef: a["profile"] as? String, profileVersionId: a["profile_version_id"] as? String,
                prompt: (a["prompt"] as? String).flatMap { $0.isEmpty ? nil : SessionPrompt(text: $0, tools: ["*"]) }, rewrite: a["rewrite"] as? Bool ?? false,
                maxRewrites: a["max_rewrites"] as? Int)
            if a["profile_draft"] != nil { req.profile = try object(a, "profile_draft", as: Profile.self) }
            if req.rewrite, s.readOnly { throw MCPServer.ToolError("this server is read-only: rewrite=true calls the paid rewrite agent; use rewrite=false") }
            let r = try await s.daemon().whatIf(req)
            var out = ["What if: \(r.rulesLabel) on “\(r.sessionName)” (\(r.items.count) tool results)"]
            out += WhatIfChange.allCases.compactMap { c in r.count(c) > 0 ? "- \(r.count(c)) \(c.label)" : nil }
            if r.rewrite {
                out.append("Rewrite cost: $\(String(format: "%.4f", r.costUSD))")
            } else if r.calls > 0 {
                out.append("A full run makes \(r.calls) rewrite call(s), estimated $\(String(format: "%.3f", r.estimateLowUSD))–$\(String(format: "%.3f", r.estimateHighUSD)). Ask the user before calling again with rewrite=true.")
            }
            for i in r.items where ![.sameUnchanged, .sameRewrite].contains(i.change) {
                out.append("\n\(i.toolName) \(i.toolUseId)\(target(i.toolName, i.toolInput).map { " (\($0))" } ?? ""): \(i.change.label); before \(i.before.rawValue) (\(i.beforeReason))")
                if !i.matchedRules.isEmpty { out.append("  rules: \(i.matchedRules.joined(separator: ", "))") }
                if let e = i.afterExplanation { out.append("  new rewrite: \(e)") }
                if let t = i.afterText { out.append("  new text: \(clip(t, 1500))") }
            }
            return out.joined(separator: "\n")
        },

        // Changes
        .init(
            name: "create_profile",
            description: "Create a profile (version 1). Rules: {name, match: {tools: [globs], input: {field: regex}, content: regex, stage: result|page}, instructions, model?, context: none|task}. Later rules take priority.",
            schema: schema(["profile": ["type": "object", "description": "{name, description, rules: [...], defaults?}"]], required: ["profile"]), readOnly: false
        ) { s, a in
            let v = try await s.daemon().createProfile(try object(a, "profile", as: Profile.self))
            return "Created profile “\(v.profile.name)” (\(v.profileId)) version \(v.number)."
        },
        .init(
            name: "update_profile", description: "Save a new version of a profile. Earlier versions stay for audit; sessions already running keep the version they started with.",
            schema: schema(["profile_id": string("Profile name or id."), "profile": ["type": "object", "description": "The complete new profile (see get_profile)."]], required: ["profile_id", "profile"]),
            readOnly: false
        ) { s, a in
            let d = try await s.daemon().updateProfile(try arg(a, "profile_id"), try object(a, "profile", as: Profile.self))
            return "Saved “\(d.current.profile.name)” as version \(d.current.number)."
        },
        .init(
            name: "install_hook",
            description: "Connect a project folder to Diorama through Claude Code hooks (writes .claude/settings.local.json). New Claude Code sessions in that folder, including the Claude desktop app's Code tab, then have their tool results rewritten by the profile or prompt and recorded. Replaces an existing Diorama hook there.",
            schema: schema([
                "folder": string("Absolute path of the project folder."), "profile": string("Profile name or id (optional)."),
                "prompt": string("Session prompt for the rewrite agent (optional)."),
                "prompt_tools": ["type": "array", "items": ["type": "string"], "description": "Tools the prompt applies to (default WebFetch, WebSearch)."],
                "share_task": ["type": "boolean", "description": "Give the rewrite agent the session's task (default false)."],
            ], required: ["folder"]),
            readOnly: false
        ) { s, a in
            let folder = try arg(a, "folder")
            guard FileManager.default.fileExists(atPath: (folder as NSString).expandingTildeInPath) else { throw MCPServer.ToolError("folder does not exist: \(folder)") }
            let profile = a["profile"] as? String
            if let profile, !profile.isEmpty {
                let known = try await s.daemon().profiles()
                guard known.contains(where: { $0.name == profile || $0.id == profile }) else { throw MCPServer.ToolError("unknown profile '\(profile)'") }
            }
            let prompt = (a["prompt"] as? String).flatMap { $0.isEmpty ? nil : $0 }.map {
                SessionPrompt(text: $0, tools: a["prompt_tools"] as? [String] ?? SessionPrompt.defaultTools, context: a["share_task"] as? Bool == true ? .task : .none)
            }
            let command = try HookInstaller.command(cli: s.cliPath, config: HookConfig(profile: profile?.isEmpty == true ? nil : profile, prompt: prompt))
            let url = try HookInstaller.install(command: command, settings: HookInstaller.projectSettings(folder))
            return "Installed Diorama's hook in \(url.path). Start a new Claude Code session in that folder for it to take effect."
        },
        .init(
            name: "uninstall_hook", description: "Remove Diorama's hook from a project folder's .claude/settings.local.json (other settings stay).",
            schema: schema(["folder": string("Absolute path of the project folder.")], required: ["folder"]), readOnly: false
        ) { _, a in
            let url = HookInstaller.projectSettings(try arg(a, "folder"))
            return try HookInstaller.uninstall(settings: url) ? "Removed Diorama's hook from \(url.path)." : "No Diorama hook in \(url.path)."
        },
        .init(
            name: "set_steering_paused",
            description: "Pause or resume steering, for one session (session_id) or everywhere (no session_id). While paused, tool results reach Claude unchanged: no AI rewrites or input changes, though redaction still applies. Experiment runs aren't affected.",
            schema: schema(["paused": ["type": "boolean", "description": "true to pause, false to resume."], "session_id": string("Only this session (optional).")], required: ["paused"]),
            readOnly: false
        ) { s, a in
            guard let paused = a["paused"] as? Bool else { throw MCPServer.ToolError("missing argument 'paused'") }
            if let id = a["session_id"] as? String, !id.isEmpty {
                let info = try await s.daemon().setPaused(id, paused)
                return "Steering \(paused ? "paused" : "resumed") for “\(info.name)” (\(info.id))."
            }
            _ = try await s.daemon().setSteeringPaused(paused)
            return "Steering \(paused ? "paused" : "resumed") everywhere."
        },
        .init(
            name: "annotate_session",
            description: "Rename a session, or replace its notes or tags (the user's own labels, e.g. 'baseline'). Omitted fields stay as they are; tags replace the whole list.",
            schema: schema(["session_id": string("Session id."), "name": string("New name (optional)."), "notes": string("New notes (optional; empty clears)."),
                            "tags": ["type": "array", "items": ["type": "string"], "description": "The full new list of tags (optional)."]], required: ["session_id"]),
            readOnly: false
        ) { s, a in
            let ann = SessionAnnotations(name: a["name"] as? String, notes: a["notes"] as? String, tags: a["tags"] as? [String])
            guard ann.name != nil || ann.notes != nil || ann.tags != nil else { throw MCPServer.ToolError("give at least one of name, notes or tags") }
            let info = try await s.daemon().annotate(try arg(a, "session_id"), ann)
            return "Saved “\(info.name)” (\(info.id))" + ((info.tags ?? []).isEmpty ? "." : ", tags: \((info.tags ?? []).joined(separator: ", ")).")
        },
        .init(
            name: "end_session", description: "Mark a session as ended (it stops appearing as running; its records stay).",
            schema: schema(["session_id": string("Session id.")], required: ["session_id"]), readOnly: false
        ) { s, a in
            let info = try await s.daemon().endSession(try arg(a, "session_id"))
            return "Session \(info.id) is \(info.status.rawValue)."
        },
        .init(
            name: "draft_experiment_from_session",
            description: "Prefill an experiment from a session: its task (the first prompt), project, tools and model, an unmodified control, and the session's profile (pinned to the version it used) or prompt. Returns the definition and notes; nothing is created. Review it with the user, adjust, then call create_experiment.",
            schema: schema(["session_id": string("Session id (ses_…)."), "trials_per_variant": ["type": "integer", "minimum": 1, "maximum": 200, "description": "Default 5."]], required: ["session_id"]),
            readOnly: true
        ) { s, a in
            let d = try await s.daemon().experimentDraft(sessionId: try arg(a, "session_id"), trials: (a["trials_per_variant"] as? Int) ?? 5)
            return "Notes:\n" + d.notes.map { "- \($0)" }.joined(separator: "\n") + "\n\nDefinition (pass to create_experiment as `definition`):\n" + (try json(d.definition))
        },
        .init(
            name: "create_experiment",
            description: "Define an experiment (nothing runs yet). Definition: {name, task, projectPath, claude: {allowedTools, model?, maxTurns?, maxBudgetUSD?}, variants: [{key, name, profile?, prompt?: {text, tools}}] including one unmodified control, trialsPerVariant, concurrency?, treatment?: frozen|fresh, judge?: {}}.",
            schema: schema(["definition": ["type": "object", "description": "The experiment definition."]], required: ["definition"]), readOnly: false
        ) { s, a in
            let e = try await s.daemon().createExperiment(try object(a, "definition", as: ExperimentDefinition.self))
            return "Created experiment “\(e.name)” (\(e.id)). Next: estimate_experiment_run."
        },
        .init(
            name: "estimate_experiment_run",
            description: "Prepare a run of an experiment and return its cost estimate and confirmation token. Nothing runs and nothing is spent. Show the estimate to the user before starting.",
            schema: schema(["experiment_id": string("Experiment id (exp_…).")], required: ["experiment_id"]), readOnly: false
        ) { s, a in
            let run = try await s.daemon().prepareRun(experimentId: try arg(a, "experiment_id"))
            guard let e = run.estimate else { return "Prepared run \(run.id), but no estimate was produced." }
            return """
                Prepared run \(run.id): \(e.trials) Claude Code runs.
                Estimated total: $\(String(format: "%.2f", e.totalLowUSD))–$\(String(format: "%.2f", e.totalHighUSD)) (Claude Code $\(String(format: "%.2f", e.perTrialLowUSD))–$\(String(format: "%.2f", e.perTrialHighUSD)) per trial; rewrite agent $\(String(format: "%.3f", e.rewriteLowUSD))–$\(String(format: "%.3f", e.rewriteHighUSD))). Basis: \(e.basis)
                \(e.notes.map { "- \($0)" }.joined(separator: "\n"))
                Confirmation token: \(e.confirmationToken)
                Ask the user to approve this cost, then call start_experiment_run with the run id and token (or cancel_experiment_run).
                """
        },
        MCPServer.Tool(
            name: "start_experiment_run",
            description: "Start a prepared run. This SPENDS MONEY: it launches real Claude Code sessions and rewrite-agent calls. Only call it after the user approved the estimate from estimate_experiment_run.",
            schema: schema(["run_id": string("Run id from estimate_experiment_run."), "confirmation_token": string("Token from estimate_experiment_run.")], required: ["run_id", "confirmation_token"]),
            readOnly: false, destructive: false, openWorld: true
        ) { s, a in
            let r = try await s.daemon().startRun(try arg(a, "run_id"), confirmationToken: try arg(a, "confirmation_token"))
            return "Run \(r.id) is \(r.status.rawValue) (\(r.trialsTotal) trials). Check progress with list_experiments; read results with get_run_report."
        },
        MCPServer.Tool(
            name: "cancel_experiment_run", description: "Cancel a prepared or running experiment run. Finished trials are kept.",
            schema: schema(["run_id": string("Run id.")], required: ["run_id"]), readOnly: false, destructive: true
        ) { s, a in
            let r = try await s.daemon().cancelRun(try arg(a, "run_id"))
            return "Run \(r.id) is \(r.status.rawValue)."
        },
    ]

    /// What a tool call was about, in a few words (URL host and path, query, file name, command).
    static func target(_ name: String?, _ inputJSON: String?) -> String? {
        guard let inputJSON, let data = inputJSON.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in ["url", "query", "file_path", "command", "pattern"] {
            if let v = obj[key] as? String, !v.isEmpty { return v.count > 100 ? String(v.prefix(100)) + "…" : v }
        }
        return nil
    }
}

// MARK: - Registration

/// Registers `diorama mcp serve` with the Claude desktop app (its `claude_desktop_config.json`)
/// without touching the file's other servers or settings.
public enum MCPInstaller {
    public static let serverName = "diorama"

    public static func desktopConfig(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    public static func arguments(readOnly: Bool) -> [String] { ["mcp", "serve"] + (readOnly ? ["--read-only"] : []) }

    public static func installDesktop(cli: String, readOnly: Bool, config url: URL = desktopConfig()) throws {
        var root = try HookInstaller.read(url)
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers[serverName] = ["command": cli, "args": arguments(readOnly: readOnly)]
        root["mcpServers"] = servers
        try HookInstaller.write(root, to: url)
    }

    @discardableResult
    public static func uninstallDesktop(config url: URL = desktopConfig()) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        var root = try HookInstaller.read(url)
        guard var servers = root["mcpServers"] as? [String: Any], servers[serverName] != nil else { return false }
        servers[serverName] = nil
        root["mcpServers"] = servers
        try HookInstaller.write(root, to: url)
        return true
    }

    public static func isInstalledInDesktop(config url: URL = desktopConfig()) -> Bool {
        registration(in: url) != nil
    }

    /// Where a client launches Diorama's server from, as registered.
    public struct Registration: Equatable, Sendable {
        public var command: String
        public var readOnly: Bool
        /// The registered executable no longer exists (the app was moved or deleted).
        public var isStale: Bool { !FileManager.default.isExecutableFile(atPath: command) }
    }

    /// Claude Code keeps user-scope MCP servers in `~/.claude.json` (read only; changes go through `claude mcp`).
    public static func claudeCodeConfig(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent(".claude.json")
    }

    public static func registration(in url: URL) -> Registration? {
        guard let entry = ((try? HookInstaller.read(url))?["mcpServers"] as? [String: Any])?[serverName] as? [String: Any],
              let command = entry["command"] as? String else { return nil }
        return Registration(command: command, readOnly: (entry["args"] as? [String] ?? []).contains("--read-only"))
    }
}
