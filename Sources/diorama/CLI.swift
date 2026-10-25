import ArgumentParser
import DioramaClient
import DioramaCore
import Darwin
import Foundation

@main
struct Diorama: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diorama",
        abstract: "Stage what your coding agent sees. Measure what it does.",
        discussion: "Diorama routes Claude Code sessions you start with `diorama run` through a local gateway that can rewrite tool results according to your rules, records everything, and runs A/B experiments.",
        version: DioramaVersion.current,
        subcommands: [
            Run.self, Sessions.self, Session.self, Profiles.self, Key.self, Settings.self, Daemon.self, Doctor.self, Experiment.self,
        ])
}

// MARK: - Shared helpers

struct GlobalOptions: ParsableArguments {
    @Option(name: .long, help: "Diorama data directory (default: ~/Library/Application Support/Diorama or $DIORAMA_HOME).")
    var home: String?

    var paths: DioramaPaths {
        var env = ProcessInfo.processInfo.environment
        if let home { env["DIORAMA_HOME"] = home }
        return DioramaPaths.default(environment: env)
    }

    func client(autostart: Bool = true) async throws -> ControlClient {
        try await ControlClient.connect(paths: paths, autostart: autostart)
    }
}

func eprint(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func printJSON<T: Encodable>(_ v: T) throws {
    print(String(decoding: try DioramaCoding.prettyEncoder.encode(v), as: UTF8.self))
}

func readJSONFile<T: Decodable>(_ path: String, as: T.Type) throws -> T {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    let data = try Data(contentsOf: url)
    do {
        return try DioramaCoding.decoder.decode(T.self, from: data)
    } catch {
        throw ValidationError("\(path) is not a valid \(T.self): \(error)")
    }
}

func short(_ s: String, _ n: Int) -> String {
    let flat = s.replacingOccurrences(of: "\n", with: " ")
    return flat.count > n ? String(flat.prefix(n - 1)) + "…" : flat
}

func money(_ d: Double?) -> String {
    guard let d else { return "—" }
    return d < 0.01 ? String(format: "$%.4f", d) : String(format: "$%.2f", d)
}

func dateText(_ d: Date?) -> String {
    guard let d else { return "—" }
    return d.formatted(date: .abbreviated, time: .standard)
}

func table(_ headers: [String], _ rows: [[String]]) {
    var widths = headers.map(\.count)
    for r in rows { for (i, c) in r.enumerated() where i < widths.count { widths[i] = max(widths[i], c.count) } }
    func line(_ cells: [String]) -> String {
        cells.enumerated().map { i, c in c.padding(toLength: widths[i], withPad: " ", startingAt: 0) }.joined(separator: "  ")
    }
    print(line(headers))
    print(widths.map { String(repeating: "─", count: $0) }.joined(separator: "  "))
    for r in rows { print(line(r)) }
}

extension ContextMode: ExpressibleByArgument {}
extension RuleStage: ExpressibleByArgument {}
extension LockdownPreset: ExpressibleByArgument {}
extension SessionKind: ExpressibleByArgument {}

// MARK: - run

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start Claude Code in the current folder, routed through Diorama.",
        discussion: """
            Everything after `--` is passed to Claude Code. Only this session is routed through Diorama; \
            other Claude Code sessions and your settings files are not changed.

            Examples:
              diorama run
              diorama run --profile "Web: subtle factual edit"
              diorama run --prompt "Say the library is deprecated" -- --model sonnet
            """)

    @OptionGroup var global: GlobalOptions
    @Option(help: "Session name (default: folder name).") var name: String?
    @Option(help: "Profile (global rules) to apply, by name or id.") var profile: String?
    @Option(help: "Session-specific rewrite prompt.") var prompt: String?
    @Option(help: "Read the session prompt from a file.") var promptFile: String?
    @Option(help: "Tools the session prompt applies to (comma-separated globs).") var promptTools: String = SessionPrompt.defaultTools.joined(separator: ",")
    @Option(help: "Extra context for the session prompt: none or task.") var promptContext: ContextMode = .none
    @Option(help: "Rewrite model for the session prompt (default: profile/global default).") var promptModel: String?
    @Option(help: "Where the session prompt applies: result (tool results) or page (WebFetch raw page, before summarization).") var promptStage: RuleStage = .result
    @Option(help: "Block shell network tools that bypass rewrites: none or network.") var lockdown: LockdownPreset = .none
    @Option(help: "Path to the claude executable.") var claude: String?
    @Argument(parsing: .postTerminator, help: "Arguments passed to Claude Code.") var claudeArguments: [String] = []

    func run() async throws {
        let client = try await global.client()
        var promptText = prompt
        if let f = promptFile { promptText = try String(contentsOfFile: (f as NSString).expandingTildeInPath, encoding: .utf8) }
        let sessionPrompt = promptText.map {
            SessionPrompt(text: $0, tools: promptTools.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }, context: promptContext, model: promptModel, stage: promptStage)
        }
        if claudeArguments.contains("--settings") {
            eprint("diorama: note: you passed --settings to Claude Code; Diorama also passes --settings to route this session. If yours sets ANTHROPIC_BASE_URL the session may bypass Diorama.")
        }
        let settings = try await client.settings()
        let env = ProcessInfo.processInfo.environment
        guard let claudePath = claude.map({ ($0 as NSString).expandingTildeInPath }) ?? settings.claudePath ?? findClaude(env) else {
            throw ValidationError("could not find `claude`; install Claude Code or pass --claude PATH")
        }
        let cwd = FileManager.default.currentDirectoryPath
        let launch = try await client.createSession(SessionSpec(
            name: name ?? (cwd as NSString).lastPathComponent, cwd: cwd, profile: profile, prompt: sessionPrompt, lockdown: lockdown))
        let s = launch.session
        eprint("◆ Diorama session \"\(s.name)\" (\(s.id))")
        var bits = ["profile: \(s.profileName.map { "\($0) v\(s.profileVersionNumber ?? 0)" } ?? "none")"]
        bits.append("session prompt: \(s.prompt == nil ? "none" : s.prompt!.stage == .page ? "on (WebFetch pages, before summarization)" : "on (\(s.prompt!.tools.joined(separator: ", ")))")")
        if lockdown != .none { bits.append("lockdown: \(lockdown.rawValue)") }
        eprint("  " + bits.joined(separator: " · "))
        if s.profileName != nil || s.prompt != nil {
            let key = try await client.keyStatus()
            if !key.configured { eprint("  ⚠︎ no rewrite API key configured — matching tool results will pass through unchanged (run `diorama key set`)") }
        }
        eprint("  timeline: diorama session show \(s.id)  (or open the Diorama app)")

        var childEnv = env
        for (k, v) in launch.environment { childEnv[k] = v }
        let args = claudeArguments + launch.claudeArguments
        let status = await Supervisor(paths: global.paths, port: client.info.port).run(claudePath, args, childEnv)

        if let fresh = try? await ControlClient.connect(paths: global.paths, autostart: false),
           let ended = try? await fresh.endSession(s.id) {
            let st = ended.stats
            eprint("◆ Diorama session ended: \(st.exchanges) requests · \(st.toolResults) tool results · \(st.rewrites) rewritten · \(st.failures) failed · rewrite cost \(money(st.rewriteCostUSD))")
            if st.anomalies > 0 { eprint("  ⚠︎ \(st.anomalies) anomaly event(s) — see diorama session show \(s.id)") }
        }
        throw ExitCode(status)
    }

    func findClaude(_ env: [String: String]) -> String? {
        let home = env["HOME"] ?? NSHomeDirectory()
        let dirs = (env["PATH"] ?? "").split(separator: ":").map(String.init) + ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin"]
        return dirs.map { ($0 as NSString).appendingPathComponent("claude") }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// Runs Claude Code in the foreground and keeps the daemon alive while it runs.
struct Supervisor {
    let paths: DioramaPaths
    let port: Int

    func run(_ path: String, _ args: [String], _ env: [String: String]) async -> Int32 {
        var attr = posix_spawnattr_t(bitPattern: 0)
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for s in [SIGINT, SIGQUIT, SIGTSTP, SIGTTIN, SIGTTOU, SIGHUP, SIGTERM, SIGPIPE, SIGCHLD] { sigaddset(&defaults, s) }
        posix_spawnattr_setsigdefault(&attr, &defaults)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGDEF))
        let cArgs = ([path] + args).map { strdup($0) } + [nil]
        let cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            cArgs.forEach { free($0) }
            cEnv.forEach { free($0) }
        }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, nil, &attr, cArgs, cEnv)
        guard rc == 0 else {
            eprint("diorama: could not start \(path): \(String(cString: strerror(rc)))")
            return 127
        }
        // Terminal signals go to Claude Code (same process group); we only forward termination.
        signal(SIGINT, SIG_IGN)
        signal(SIGQUIT, SIG_IGN)
        let forwarders = [SIGTERM, SIGHUP].map { sig -> DispatchSourceSignal in
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            src.setEventHandler { kill(pid, sig) }
            src.resume()
            return src
        }
        defer { forwarders.forEach { $0.cancel() } }

        var status: Int32 = 0
        var lastCheck = Date()
        var failures = 0
        while true {
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid { break }
            if r < 0, errno != EINTR { break }
            if Date().timeIntervalSince(lastCheck) > 3 {
                lastCheck = Date()
                if await daemonHealthy() {
                    failures = 0
                } else {
                    failures += 1
                    if failures == 2, let exe = DaemonLauncher.locate() {
                        eprint("\n[diorama] the daemon stopped; restarting it on port \(port)…")
                        try? DaemonLauncher.spawn(executable: exe, paths: paths, extraArguments: ["--port", String(port), "--exact-port"])
                    }
                }
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        if (status & 0x7F) == 0 { return (status >> 8) & 0xFF }
        return 128 + (status & 0x7F)
    }

    func daemonHealthy() async -> Bool {
        guard let info = DaemonInfo.read(from: paths.daemonInfo), info.port == port else { return false }
        return (try? await ControlClient(info: info).health()) != nil
    }
}

// MARK: - sessions / session

struct Sessions: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List Diorama sessions.")
    @OptionGroup var global: GlobalOptions
    @Option(help: "Filter by kind: interactive or trial.") var kind: SessionKind?
    @Option(help: "Maximum number of sessions.") var limit = 50
    @Flag(help: "Print JSON.") var json = false

    func run() async throws {
        let list = try await global.client().sessions(kind: kind, limit: limit)
        if json { return try printJSON(list) }
        if list.isEmpty { return print("No sessions yet. Start one with `diorama run`.") }
        table(["ID", "NAME", "STATUS", "PROFILE", "REQS", "RESULTS", "REWRITES", "FAILS", "STARTED"], list.map { s in
            [s.id, short(s.name, 28), s.status.rawValue, s.profileName.map { "\($0) v\(s.profileVersionNumber ?? 0)" } ?? (s.prompt != nil ? "(prompt)" : "—"),
             String(s.stats.exchanges), String(s.stats.toolResults), String(s.stats.rewrites), String(s.stats.failures), dateText(s.createdAt)]
        })
    }
}

struct Session: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Inspect a session.", subcommands: [Show.self, Decision.self, Watch.self, End.self])

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show a session's timeline.")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "Session id.") var id: String
        @Flag(help: "Print JSON.") var json = false

        func run() async throws {
            let t = try await global.client().timeline(id)
            if json { return try printJSON(t) }
            let s = t.session
            print("\(s.name) (\(s.id)) — \(s.status.rawValue), \(s.cwd)")
            print("profile: \(s.profileName.map { "\($0) v\(s.profileVersionNumber ?? 0) [\(s.profileVersionId ?? "")]" } ?? "none") · prompt: \(s.prompt.map { short($0.text, 60) } ?? "none") · lockdown: \(s.lockdown.rawValue)")
            if !s.flags.isEmpty { print("flags: \(s.flags.joined(separator: ", "))") }
            print("")
            let decisions = Dictionary(uniqueKeysWithValues: t.decisions.map { ($0.toolUseId, $0) })
            for e in t.exchanges {
                let u = e.usage.map { "in \($0.inputTokens) · out \($0.outputTokens) · cache r/w \($0.cacheReadTokens)/\($0.cacheWriteTokens)" } ?? ""
                print("#\(e.id) \(e.method) \(e.path) [\(e.requestClass ?? "?")] → \(e.status.map(String.init) ?? "…")  \(u)  +\(Int(e.addedLatencyMs ?? 0))ms")
                for tr in e.toolResults where tr.handling != .replayedUnchanged {
                    let d = decisions[tr.toolUseId]
                    let mark: String
                    switch tr.handling {
                    case .decidedRewritten: mark = "✎ rewritten"
                    case .replayedRewritten: mark = "↻ replayed rewrite"
                    case .decidedFailed, .replayedFailed: mark = "✗ failed"
                    case .decidedUnchanged: mark = "· unchanged"
                    case .clientModified: mark = "⚠︎ client-modified"
                    default: mark = "· \(tr.handling.rawValue)"
                    }
                    if tr.handling == .replayedRewritten || tr.handling == .replayedFailed { continue }
                    print("    \(mark) \(tr.toolName ?? "?") \(tr.toolUseId)\(d.map { " — \(short($0.reason, 90))" } ?? "")")
                }
                if let a = e.assistant {
                    if !a.text.isEmpty { print("    ⟶ \(short(a.text, 110))") }
                    for u in a.toolUses { print("    ⟶ calls \(u.name) \(short(u.input, 90))") }
                }
                if let err = e.error { print("    ! \(err)") }
            }
            let anomalies = t.events.filter { $0.kind == .anomaly || $0.kind == .rewriteFailed }
            if !anomalies.isEmpty {
                print("\nEvents:")
                for ev in anomalies { print("  \(ev.kind.rawValue): \(ev.message)") }
            }
        }
    }

    struct Decision: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show the audit record for one tool result (original, rewrite, diff, rules, explanation).")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "tool_use_id.") var toolUseId: String
        @Flag(help: "Print JSON.") var json = false

        func run() async throws {
            let d = try await global.client().decision(toolUseId)
            if json { return try printJSON(d) }
            let s = d.summary
            print("\(s.toolName ?? "?") \(s.toolUseId) — \(s.outcome.rawValue.uppercased()) (replayed \(s.replayCount)×)")
            print("reason: \(s.reason)")
            if let i = d.toolInput { print("input: \(short(i, 200))") }
            if !s.rules.isEmpty { print("rules: " + s.rules.map { "\($0.name) [\($0.ruleHash)]" }.joined(separator: ", ")) }
            for ins in d.instructions { print("instruction: \(ins)") }
            for a in d.attempts {
                print("attempt \(a.id): \(a.status.rawValue) · \(a.modelServed ?? a.modelRequested) · \(Int(a.latencyMs))ms · \(money(a.costUSD))\(a.error.map { " · \($0)" } ?? "")")
                if let e = a.explanation { print("  explanation: \(e)") }
                for e in a.edits { print("  edit: \(short(e.find, 60)) → \(short(e.replace, 60))  (\(e.rationale))") }
            }
            if let r = d.replacementText {
                print("\n--- diff (word level: [-removed-] {+added+}) ---")
                print(TextDiff.inline(TextDiff.diff(d.originalText, r)))
            } else {
                print("\n--- original ---\n\(d.originalText)")
            }
            if let f = d.followUp {
                print("\n--- Claude's next response ---")
                if !f.text.isEmpty { print(f.text) }
                for u in f.toolUses { print("calls \(u.name) \(short(u.input, 120))") }
            }
        }
    }

    struct Watch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stream live events for a session (or all sessions).")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "Session id (omit for all).") var id: String?

        func run() async throws {
            let c = try await global.client()
            print("Watching \(id ?? "all sessions") — Ctrl-C to stop")
            for try await e in c.eventStream(session: id) {
                print("\(e.createdAt.formatted(date: .omitted, time: .standard)) \(e.sessionId ?? "-") \(e.kind.rawValue): \(e.message)")
            }
        }
    }

    struct End: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Mark a session as ended.")
        @OptionGroup var global: GlobalOptions
        @Argument var id: String
        func run() async throws { print(try await global.client().endSession(id).status.rawValue) }
    }
}

// MARK: - profiles

struct Profiles: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage profiles (versioned sets of global rules).",
        subcommands: [List.self, Show.self, Create.self, Update.self, Export.self, Delete.self, Templates.self], defaultSubcommand: List.self)

    struct List: AsyncParsableCommand {
        @OptionGroup var global: GlobalOptions
        @Flag var json = false
        func run() async throws {
            let ps = try await global.client().profiles()
            if json { return try printJSON(ps) }
            if ps.isEmpty { return print("No profiles. Create one with `diorama profiles create --file profile.json` or `--template N`.") }
            table(["ID", "NAME", "VERSION", "RULES", "UPDATED"], ps.map { [$0.id, $0.name, "v\($0.currentVersionNumber)", String($0.ruleCount), dateText($0.updatedAt)] })
        }
    }

    struct Show: AsyncParsableCommand {
        @OptionGroup var global: GlobalOptions
        @Argument(help: "Profile id or name.") var id: String
        @Flag var json = false
        func run() async throws {
            let d = try await global.client().profile(id)
            if json { return try printJSON(d) }
            let p = d.current.profile
            print("\(p.name) — v\(d.current.number) [\(d.current.id)]\(p.description.isEmpty ? "" : "\n\(p.description)")")
            print("defaults: model \(p.defaults.model), on failure \(p.defaults.onFailure.rawValue), max input \(p.defaults.maxInputChars) chars, timeout \(Int(p.defaults.timeoutSeconds))s")
            for r in p.rules {
                print("\n• \(r.name)\(r.enabled ? "" : " (disabled)") [\(r.id)]")
                print("  stage: \(r.match.stage.rawValue) · tools: \(r.match.tools.joined(separator: ", "))\(r.match.input.isEmpty ? "" : " · input: \(r.match.input)")\(r.match.content.map { " · content: /\($0)/" } ?? "")")
                print("  context: \(r.context.rawValue)\(r.model.map { " · model: \($0)" } ?? "")")
                print("  instructions: \(r.instructions)")
            }
            print("\nversions: " + d.versions.map { "v\($0.number) (\(dateText($0.createdAt)))" }.joined(separator: ", "))
        }
    }

    struct Create: AsyncParsableCommand {
        @OptionGroup var global: GlobalOptions
        @Option(help: "Profile JSON file.") var file: String?
        @Option(help: "Start from built-in template number (see `diorama profiles templates`).") var template: Int?
        @Option(help: "Name (overrides the file/template name).") var name: String?
        func run() async throws {
            let c = try await global.client()
            var p: Profile
            if let file {
                p = try readJSONFile(file, as: Profile.self)
            } else if let template {
                let all = try await c.templates()
                guard all.indices.contains(template - 1) else { throw ValidationError("no template \(template)") }
                p = all[template - 1]
            } else {
                throw ValidationError("pass --file or --template")
            }
            if let name { p.name = name }
            let v = try await c.createProfile(p)
            print("Created profile '\(v.profile.name)' (\(v.profileId)) v\(v.number)")
        }
    }

    struct Update: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Save a new version of a profile from a JSON file.")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "Profile id or name.") var id: String
        @Option(help: "Profile JSON file.") var file: String
        func run() async throws {
            let d = try await global.client().updateProfile(id, try readJSONFile(file, as: Profile.self))
            print("'\(d.current.profile.name)' is now v\(d.current.number). Existing sessions keep the version they started with.")
        }
    }

    struct Export: AsyncParsableCommand {
        @OptionGroup var global: GlobalOptions
        @Argument var id: String
        @Option(help: "Write to a file instead of stdout.") var output: String?
        func run() async throws {
            let d = try await global.client().profile(id)
            let data = try DioramaCoding.prettyEncoder.encode(d.current.profile)
            if let output { try data.write(to: URL(fileURLWithPath: (output as NSString).expandingTildeInPath)) } else { print(String(decoding: data, as: UTF8.self)) }
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Archive a profile (its versions stay for audit).")
        @OptionGroup var global: GlobalOptions
        @Argument var id: String
        func run() async throws {
            try await global.client().archiveProfile(id)
            print("Archived.")
        }
    }

    struct Templates: AsyncParsableCommand {
        @OptionGroup var global: GlobalOptions
        @Flag var json = false
        func run() async throws {
            let t = try await global.client().templates()
            if json { return try printJSON(t) }
            for (i, p) in t.enumerated() { print("\(i + 1). \(p.name) — \(p.description)") }
            print("\nCreate one with: diorama profiles create --template N [--name NAME]")
        }
    }
}

// MARK: - key / settings

struct Key: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage the Anthropic API key used by the rewrite agent (stored in the macOS Keychain).",
        subcommands: [Set.self, Status.self, Delete.self], defaultSubcommand: Status.self)

    struct Set: AsyncParsableCommand {
        @OptionGroup var global: GlobalOptions
        @Flag(help: "Read the key from standard input instead of prompting.") var stdin = false
        func run() async throws {
            var key: String?
            if stdin || isatty(0) == 0 {
                key = readLine(strippingNewline: true)
            } else {
                var buf = [CChar](repeating: 0, count: 512)
                if let p = readpassphrase("Anthropic API key (input hidden): ", &buf, buf.count, 0) { key = String(cString: p) }
            }
            guard let key, !key.isEmpty else { throw ValidationError("no key entered") }
            let s = try await global.client().setKey(key)
            print("Saved to \(s.source ?? "keychain") (\(s.hint ?? "")). This key is used only for rewrite-agent calls.")
        }
    }

    struct Status: AsyncParsableCommand {
        @OptionGroup var global: GlobalOptions
        func run() async throws {
            let s = try await global.client().keyStatus()
            print(s.configured ? "Configured via \(s.source ?? "?") (\(s.hint ?? ""))." : "Not configured. Run `diorama key set`.")
        }
    }

    struct Delete: AsyncParsableCommand {
        @OptionGroup var global: GlobalOptions
        func run() async throws {
            _ = try await global.client().deleteKey()
            print("Removed from the Keychain.")
        }
    }
}

struct Settings: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show or change settings.", subcommands: [Show.self, SetValue.self], defaultSubcommand: Show.self)

    struct Show: AsyncParsableCommand {
        @OptionGroup var global: GlobalOptions
        func run() async throws { try printJSON(try await global.client().settings()) }
    }

    struct SetValue: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "set", abstract: "Set defaultModel, retentionDays, captureRawBodies, claudePath or ollamaURL.")
        @OptionGroup var global: GlobalOptions
        @Argument var key: String
        @Argument var value: String
        func run() async throws {
            let c = try await global.client()
            var s = try await c.settings()
            switch key {
            case "defaultModel": s.defaultModel = value
            case "retentionDays":
                guard let d = Int(value) else { throw ValidationError("retentionDays must be a number") }
                s.retentionDays = d
            case "captureRawBodies": s.captureRawBodies = ["1", "true", "yes", "on"].contains(value.lowercased())
            case "claudePath": s.claudePath = value.isEmpty ? nil : (value as NSString).expandingTildeInPath
            case "ollamaURL":
                guard URL(string: value)?.scheme?.hasPrefix("http") == true else { throw ValidationError("ollamaURL must be an http(s) URL") }
                s.ollamaURL = value
            default: throw ValidationError("unknown setting \(key)")
            }
            try printJSON(try await c.saveSettings(s))
        }
    }
}

// MARK: - daemon / doctor

struct Daemon: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Control the background service.", subcommands: [Start.self, Stop.self, Status.self, Logs.self, Install.self, Uninstall.self],
        defaultSubcommand: Status.self)

    struct Start: AsyncParsableCommand {
        @OptionGroup var global: GlobalOptions
        func run() async throws {
            let c = try await global.client(autostart: true)
            print("Running (pid \(c.info.pid), port \(c.info.port)).")
        }
    }

    struct Stop: AsyncParsableCommand {
        @OptionGroup var global: GlobalOptions
        func run() async throws {
            guard let c = try? await global.client(autostart: false) else { return print("Not running.") }
            try await c.shutdown()
            print("Stopping. Routed Claude Code sessions will lose their connection until the daemon starts again.")
        }
    }

    struct Status: AsyncParsableCommand {
        @OptionGroup var global: GlobalOptions
        func run() async throws {
            guard let c = try? await global.client(autostart: false), let h = try? await c.health() else {
                return print("Not running. (`diorama run` starts it automatically.)")
            }
            print("Running: version \(h.version), pid \(h.pid), 127.0.0.1:\(h.port), \(h.activeSessions) active session(s), data \(h.dataDirectory)")
        }
    }

    struct Logs: AsyncParsableCommand {
        @OptionGroup var global: GlobalOptions
        @Option(help: "Number of lines.") var lines = 50
        func run() async throws {
            let path = global.paths.logs.appendingPathComponent("dioramad.log").path
            let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            print(text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n"))
        }
    }

    static let agentLabel = "io.github.diorama.daemon"
    static var agentPlist: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist") }

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Opt in: start the daemon automatically at login (LaunchAgent).")
        @OptionGroup var global: GlobalOptions
        func run() async throws {
            guard let exe = DaemonLauncher.locate() else { throw ValidationError("could not find dioramad") }
            let plist: [String: Any] = [
                "Label": Daemon.agentLabel, "ProgramArguments": [exe, "--home", global.paths.home.path], "RunAtLoad": true,
                "KeepAlive": ["SuccessfulExit": false],
                "StandardOutPath": global.paths.logs.appendingPathComponent("dioramad.log").path,
                "StandardErrorPath": global.paths.logs.appendingPathComponent("dioramad.log").path,
            ]
            try global.paths.ensureDirectories()
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try FileManager.default.createDirectory(at: Daemon.agentPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: Daemon.agentPlist)
            if let c = try? await global.client(autostart: false) { try? await c.shutdown(); try await Task.sleep(for: .seconds(1)) }
            let r = try launchctl(["bootstrap", "gui/\(getuid())", Daemon.agentPlist.path])
            print(r == 0 ? "Installed \(Daemon.agentPlist.path). The daemon now starts at login." : "Wrote \(Daemon.agentPlist.path) but launchctl bootstrap failed (\(r)).")
        }
    }

    struct Uninstall: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove the login LaunchAgent.")
        func run() async throws {
            _ = try? launchctl(["bootout", "gui/\(getuid())/\(Daemon.agentLabel)"])
            if FileManager.default.fileExists(atPath: Daemon.agentPlist.path) { try FileManager.default.removeItem(at: Daemon.agentPlist) }
            print("Removed the LaunchAgent (if it was installed).")
        }
    }
}

func launchctl(_ args: [String]) throws -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = args
    try p.run()
    p.waitUntilExit()
    return p.terminationStatus
}

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check that Diorama and Claude Code are set up correctly.")
    @OptionGroup var global: GlobalOptions
    @Flag var json = false

    func run() async throws {
        var checks: [DoctorCheck] = []
        do {
            let c = try await global.client()
            let h = try await c.health()
            checks.append(DoctorCheck(name: "Daemon", status: h.version == DioramaVersion.current ? .ok : .warning,
                                      detail: "running \(h.version) on 127.0.0.1:\(h.port)" + (h.version == DioramaVersion.current ? "" : " — CLI is \(DioramaVersion.current); restart the daemon")))
            checks += try await c.doctor().checks
        } catch {
            checks.append(DoctorCheck(name: "Daemon", status: .failure, detail: "\(error)"))
        }
        if json { return try printJSON(DoctorReport(checks: checks)) }
        for c in checks {
            let icon = c.status == .ok ? "✓" : c.status == .warning ? "!" : "✗"
            print("\(icon) \(c.name): \(c.detail)")
        }
        if checks.contains(where: { $0.status == .failure }) { throw ExitCode(1) }
    }
}
