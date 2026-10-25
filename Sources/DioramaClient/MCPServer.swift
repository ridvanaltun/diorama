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
    let readOnly: Bool
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
            return "Diorama \(health.version), daemon pid \(health.pid) on 127.0.0.1:\(health.port), \(health.activeSessions) active session(s), data in \(health.dataDirectory)\n\(checks)"
        },
        .init(
            name: "list_sessions", description: "Recent Diorama sessions with their profile, mode (gateway or hook) and counts of tool results, rewrites and failures.",
            schema: schema(["kind": ["type": "string", "enum": ["interactive", "trial"], "description": "Only this kind (default: all)."],
                            "limit": ["type": "integer", "minimum": 1, "maximum": 200, "description": "Default 20."]]),
            readOnly: true
        ) { s, a in
            let kind = (a["kind"] as? String).flatMap(SessionKind.init(rawValue:))
            let rows = try await s.daemon().sessions(kind: kind, limit: (a["limit"] as? Int) ?? 20)
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
            name: "get_run_report", description: "An experiment run's report (Markdown): facts per variant, heuristic signals with intervals, caveats, and every trial.",
            schema: schema(["run_id": string("Run id (run_…).")], required: ["run_id"]), readOnly: true
        ) { s, a in
            clip(try await s.daemon().report(try arg(a, "run_id"), format: "md"), 20000)
        },
        .init(
            name: "get_hook_status", description: "Whether a project folder has Diorama's Claude Code hook (hook mode, used by the Claude desktop app and IDEs), and its configuration.",
            schema: schema(["folder": string("Absolute path of the project folder.")], required: ["folder"]), readOnly: true
        ) { _, a in
            let url = HookInstaller.projectSettings(try arg(a, "folder"))
            guard let command = HookInstaller.installedCommand(settings: url) else { return "No Diorama hook in \(url.path)" }
            return "Diorama hook installed in \(url.path):\n\(command)"
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
            name: "end_session", description: "Mark a session as ended (it stops appearing as running; its records stay).",
            schema: schema(["session_id": string("Session id.")], required: ["session_id"]), readOnly: false
        ) { s, a in
            let info = try await s.daemon().endSession(try arg(a, "session_id"))
            return "Session \(info.id) is \(info.status.rawValue)."
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
