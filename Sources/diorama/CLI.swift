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
            Run.self, Hook.self, MCP.self, Spend.self, Search.self, PauseAll.self, ResumeAll.self, Reviews.self, ExportData.self, Folders.self, Sessions.self, Session.self, Profiles.self, Key.self, Settings.self, Daemon.self, Doctor.self, Experiment.self, Update.self,
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
    @Flag(help: "Don't use the folder's default profile (see `diorama folders`).") var noFolderDefault = false
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
        var profile = profile
        // No profile or prompt given: use the folder's default, if one is set.
        if profile == nil, sessionPrompt == nil, !noFolderDefault, let d = settings.folderDefault(for: cwd), let p = d.profile {
            if try await client.profiles().contains(where: { $0.name == p || $0.id == p }) {
                profile = p
                eprint("◆ Using \(p), the default profile for \(d.path) (--no-folder-default to skip)")
            } else {
                eprint("diorama: note: \(d.path)'s default profile '\(p)' no longer exists; running without a profile. Fix it with `diorama folders set`.")
            }
        }
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

}

func findClaude(_ env: [String: String]) -> String? {
    let home = env["HOME"] ?? NSHomeDirectory()
    let dirs = (env["PATH"] ?? "").split(separator: ":").map(String.init) + ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin"]
    return dirs.map { ($0 as NSString).appendingPathComponent("claude") }.first { FileManager.default.isExecutableFile(atPath: $0) }
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
    @Option(help: "Only sessions with this tag.") var tag: String?
    @Flag(help: "List archived sessions instead.") var archived = false
    @Option(help: "Maximum number of sessions.") var limit = 50
    @Flag(help: "Print JSON.") var json = false

    func run() async throws {
        let list = try await global.client().sessions(kind: kind, tag: tag, archived: archived ? "only" : "hide", limit: limit)
        if json { return try printJSON(list) }
        if list.isEmpty { return print("No sessions yet. Start one with `diorama run`.") }
        table(["ID", "NAME", "STATUS", "PROFILE", "REQS", "RESULTS", "REWRITES", "FAILS", "STARTED", "TAGS"], list.map { s in
            [s.id, short(s.name, 28), s.status.rawValue, s.profileName.map { "\($0) v\(s.profileVersionNumber ?? 0)" } ?? (s.prompt != nil ? "(prompt)" : "—"),
             String(s.stats.exchanges), String(s.stats.toolResults), String(s.stats.rewrites), String(s.stats.failures), dateText(s.createdAt),
             short((s.tags ?? []).joined(separator: ","), 30)]
        })
    }
}

struct Session: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Inspect a session.", subcommands: [Show.self, Decision.self, Watch.self, End.self, Pause.self, Resume.self, WhatIf.self, ToExperiment.self, Report.self, Note.self, Tag.self, Rename.self, Compare.self, Archive.self, Unarchive.self])

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
            if s.isHook {
                // Hook mode has no model requests to show: list the tool results Diorama decided.
                print("hook mode (Claude desktop / IDE): tool results only, no model traffic\n")
                for d in t.decisions.sorted(by: { $0.createdAt < $1.createdAt }) {
                    let mark = d.outcome == .rewritten ? "✎ rewritten" : d.outcome == .failed ? "✗ failed" : "· unchanged"
                    print("    \(mark) \(d.toolName ?? "?") \(d.toolUseId) — \(short(d.reason, 90))")
                }
            }
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
            let anomalies = t.events.filter { $0.kind == .anomaly || $0.kind == .rewriteFailed || $0.kind == .warning }
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

    struct Archive: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Archive sessions: hide them from the list (nothing is deleted; search and exports still include them).",
            discussion: """
                  diorama session archive ses_abc ses_def
                  diorama session archive --older-than 30          # every ended session started more than 30 days ago
                Running sessions are skipped. List archived ones with `diorama sessions --archived`.
                """)
        @OptionGroup var global: GlobalOptions
        @Argument(help: "Session ids.") var ids: [String] = []
        @Option(help: "Also archive every ended session started more than this many days ago.") var olderThan: Int?
        @Option(help: "With --older-than: only interactive sessions or only trials.") var kind: SessionKind?
        func run() async throws {
            guard !ids.isEmpty || olderThan != nil else { throw ValidationError("give session ids or --older-than DAYS") }
            let n = try await global.client().archiveSessions(ArchiveRequest(sessionIds: ids, olderThanDays: olderThan, kind: kind))
            print("✓ Archived \(n) session(s).")
        }
    }

    struct Unarchive: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show archived sessions in the list again.")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "Session ids.") var ids: [String]
        func run() async throws {
            let n = try await global.client().archiveSessions(ArchiveRequest(sessionIds: ids, archived: false))
            print("✓ Unarchived \(n) session(s).")
        }
    }

    struct Compare: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Compare two sessions side by side: counts, cost, duration, tools, rules and Claude's final answers.",
            discussion: "diorama session compare ses_baseline ses_steered   (for a measured comparison with a control, use an experiment)")
        @OptionGroup var global: GlobalOptions
        @Argument var a: String
        @Argument var b: String
        @Flag var json = false
        func run() async throws {
            let c = try await global.client().compareSessions(a, b)
            if json { return try printJSON(c) }
            print(c.text)
        }
    }

    struct Note: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show or set a session's notes.",
            discussion: "diorama session note ses_abc \"Baseline: steering off, docs v2\"   (an empty string clears the notes; --file reads them from a file)")
        @OptionGroup var global: GlobalOptions
        @Argument var id: String
        @Argument(help: "New notes (omit to print the current ones).") var text: String?
        @Option(help: "Read the notes from a file.") var file: String?
        func run() async throws {
            let client = try await global.client()
            var notes = text
            if let file { notes = try String(contentsOfFile: (file as NSString).expandingTildeInPath, encoding: .utf8) }
            guard let notes else { return print(try await client.session(id).notes ?? "") }
            let s = try await client.annotate(id, SessionAnnotations(notes: notes))
            print(notes.isEmpty ? "✓ Cleared the notes of “\(s.name)”." : "✓ Saved notes for “\(s.name)”.")
        }
    }

    struct Tag: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add or remove a session's tags (with neither, print them).",
            discussion: "diorama session tag ses_abc --add baseline --add docs-v2 --remove draft      ·  list by tag: diorama sessions --tag baseline")
        @OptionGroup var global: GlobalOptions
        @Argument var id: String
        @Option(help: "Tag to add (repeatable).") var add: [String] = []
        @Option(help: "Tag to remove (repeatable).") var remove: [String] = []
        func run() async throws {
            let client = try await global.client()
            let current = try await client.session(id).tags ?? []
            guard !add.isEmpty || !remove.isEmpty else { return print(current.isEmpty ? "No tags." : current.joined(separator: ", ")) }
            let drop = Set(remove.map { $0.lowercased() })
            let s = try await client.annotate(id, SessionAnnotations(tags: current.filter { !drop.contains($0.lowercased()) } + add))
            let tags = s.tags ?? []
            print(tags.isEmpty ? "✓ “\(s.name)” has no tags." : "✓ “\(s.name)”: \(tags.joined(separator: ", "))")
        }
    }

    struct Rename: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Rename a session.")
        @OptionGroup var global: GlobalOptions
        @Argument var id: String
        @Argument var name: String
        func run() async throws {
            let s = try await global.client().annotate(id, SessionAnnotations(name: name))
            print("✓ Renamed to “\(s.name)”.")
        }
    }

    struct Pause: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Pause steering for a session: tool results reach Claude unchanged (redaction still applies).")
        @OptionGroup var global: GlobalOptions
        @Argument var id: String
        func run() async throws {
            let s = try await global.client().setPaused(id, true)
            print("⏸ Steering paused for “\(s.name)”. Resume with `diorama session resume \(s.id)`.")
        }
    }

    struct Resume: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Resume steering for a session.")
        @OptionGroup var global: GlobalOptions
        @Argument var id: String
        func run() async throws {
            let s = try await global.client().setPaused(id, false)
            print("▶ Steering resumed for “\(s.name)”.")
        }
    }

    struct Report: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Export a session's audit trail as Markdown or self-contained HTML.",
            discussion: "Includes what Diorama changed (diffs, rules, rewrite agent, what Claude did next), what it left unchanged, and notices.")
        @OptionGroup var global: GlobalOptions
        @Argument var id: String
        @Option(help: "md or html.") var format = "md"
        @Option(help: "Write to a file instead of printing.") var output: String?

        func run() async throws {
            let text = try await global.client().sessionReport(id, format: format)
            if let output {
                try text.write(toFile: (output as NSString).expandingTildeInPath, atomically: true, encoding: .utf8)
                print("Wrote \(output)")
            } else {
                print(text)
            }
        }
    }

    struct ToExperiment: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "experiment",
            abstract: "Draft an experiment from a session: same task and project, an unmodified control, and the session's steering.",
            discussion: """
                Prints the definition (JSON) to review or edit; with --create, registers it. Nothing runs until you \
                run it and approve its cost estimate.

                Examples:
                  diorama session experiment ses_123 > exp.json      # edit, then: diorama experiment run exp.json
                  diorama session experiment ses_123 --trials 10 --create
                """)
        @OptionGroup var global: GlobalOptions
        @Argument var id: String
        @Option(help: "Trials per variant (default 5).") var trials: Int = 5
        @Flag(help: "Register the experiment instead of printing it.") var create = false

        func run() async throws {
            let client = try await global.client()
            let draft = try await client.experimentDraft(sessionId: id, trials: trials)
            for n in draft.notes { eprint("note: \(n)") }
            guard create else { return try printJSON(draft.definition) }
            guard !draft.definition.task.isEmpty else { throw ValidationError("the session's task wasn't recorded; print the draft, add a task, then `diorama experiment run FILE`") }
            let e = try await client.createExperiment(draft.definition)
            print("✓ Created experiment “\(e.name)” (\(e.id)): \(e.definition.variants.count) variants × \(e.definition.trialsPerVariant) trials.")
            print("  Estimate and run it from the app, or: diorama experiment run \(e.id)")
        }
    }

    struct WhatIf: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "whatif",
            abstract: "Re-run a session's tool results through other rules and compare with what happened.",
            discussion: """
                Without --rewrite this only checks which rules match and estimates the cost (free). With --rewrite it \
                calls the rewrite agent for each matching result (at most --max). Nothing is recorded.

                Examples:
                  diorama session whatif ses_123 --profile "Docs steer"            # the profile's current version
                  diorama session whatif ses_123 --version pv_abc --rewrite
                  diorama session whatif ses_123 --file draft.json --rewrite --max 10
                """)
        @OptionGroup var global: GlobalOptions
        @Argument var id: String
        @Option(help: "Saved profile (current version), by name or id.") var profile: String?
        @Option(help: "A specific saved profile version (pv_…).") var version: String?
        @Option(help: "A profile JSON file (e.g. an unsaved draft).") var file: String?
        @Option(help: "A session prompt to add (applies to every tool).") var prompt: String?
        @Flag(help: "Run the rewrite agent on matching results (costs money).") var rewrite = false
        @Option(help: "At most this many rewrite calls (default 25, at most 60).") var max: Int?
        @Flag var json = false

        func run() async throws {
            var req = WhatIfRequest(sessionId: id, profileRef: profile, profileVersionId: version, prompt: prompt.map { SessionPrompt(text: $0, tools: ["*"]) },
                                    rewrite: rewrite, maxRewrites: max)
            if let file { req.profile = try readJSONFile(file, as: Profile.self) }
            let r = try await global.client().whatIf(req)
            if json { return try printJSON(r) }
            print("What if: \(r.rulesLabel) on “\(r.sessionName)” (\(r.items.count) tool results)")
            for c in WhatIfChange.allCases where r.count(c) > 0 { print("  \(r.count(c)) \(c.label)") }
            if r.rewrite {
                print("  rewrite cost \(money(r.costUSD))")
            } else if r.calls > 0 {
                print("\nA full run makes \(r.calls) rewrite call(s), about \(money(r.estimateLowUSD))–\(money(r.estimateHighUSD)). Add --rewrite to run them.")
            }
            for i in r.items where ![.sameUnchanged, .sameRewrite].contains(i.change) {
                print("\n\(i.toolName) \(i.toolUseId): \(i.change.label) (before: \(i.before.rawValue))")
                if !i.matchedRules.isEmpty { print("  rules: \(i.matchedRules.joined(separator: ", "))") }
                if let e = i.afterExplanation { print("  new: \(short(e, 160))") }
                if let e = i.afterError { print("  error: \(e)") }
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
        subcommands: [List.self, Show.self, Create.self, Update.self, Export.self, Delete.self, Templates.self, Test.self, Stats.self, Diff.self, Check.self, AddTest.self], defaultSubcommand: List.self)

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

    struct AddTest: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add-test",
            abstract: "Save a recorded tool result as a rule test, expecting the rules that match it now (saves a new version).",
            discussion: "diorama profiles add-test \"Docs steer\" --decision toolu_01abc --name \"pricing page\"   (ids from `diorama session show`)")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "Profile name or id.") var profile: String
        @Option(help: "The tool result's id.") var decision: String
        @Option(help: "Test name (default: the tool and its target).") var name: String?
        func run() async throws {
            let d = try await global.client().addRuleTest(profile, decisionId: decision, name: name)
            let t = d.current.profile.tests?.first { $0.id == decision }
            let expected = d.current.profile.rules.filter { t?.expectMatch.contains($0.id) == true }.map(\.name)
            print("✓ Added “\(t?.name ?? decision)” to \(d.current.profile.name) v\(d.current.number), expecting " + (expected.isEmpty ? "no rule to match." : expected.joined(separator: ", ") + " to match."))
        }
    }

    struct Check: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run a profile's rule tests (matching only, free). Exits 1 if any fails.",
            discussion: """
                Rule tests live in the profile ("tests": sample tool results and the rules that should match them). \
                Add them in the profile editor's Tests section, or in the JSON. Useful in CI on a checked-in profile:
                  diorama profiles check --file profiles/docs-steer.json
                  diorama profiles check "Docs steer"
                """)
        @OptionGroup var global: GlobalOptions
        @Argument(help: "Saved profile name or id.") var profile: String?
        @Option(help: "A profile JSON file to check instead.") var file: String?
        @Flag var json = false

        func run() async throws {
            let client = try await global.client()
            let results: [ProfileTestResult]
            let name: String
            if let file {
                let p = try readJSONFile(file, as: Profile.self)
                results = try await client.runProfileTests(profile: p)
                name = p.name
            } else {
                guard let profile else { throw ValidationError("give a profile or --file") }
                results = try await client.runProfileTests(profile)
                name = profile
            }
            if json { try printJSON(results) } else { print(ProfileTestsText.render(results, profileName: name)) }
            if results.contains(where: { !$0.passed }) { throw ExitCode(1) }
        }
    }

    struct Diff: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show what changed between two versions of a profile, rule by rule.",
            discussion: """
                Examples:
                  diorama profiles diff "Docs steer"              # the previous version vs the current one
                  diorama profiles diff "Docs steer" --from 1 --to 3
                """)
        @OptionGroup var global: GlobalOptions
        @Argument(help: "Profile name or id.") var profile: String
        @Option(help: "Older version number (default: the one before --to).") var from: Int?
        @Option(help: "Newer version number (default: the current one).") var to: Int?
        @Flag var json = false

        func run() async throws {
            let detail = try await global.client().profile(profile)
            let (a, b) = try ProfileComparison.versions(detail, from: from, to: to)
            let c = ProfileComparison.compare(a.profile, b.profile)
            if json { return try printJSON(c) }
            print(c.text(from: "v\(a.number)", to: "v\(b.number)"))
        }
    }

    struct Stats: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show how often each rule of a profile matched, what came of it and what it cost.",
            discussion: """
                Counts tool results from all versions of the profile. Rules that never matched show up too, so \
                you can spot rules to fix or remove. Experiment trials are left out unless you pass --trials.
                """)
        @OptionGroup var global: GlobalOptions
        @Argument(help: "Profile name or id.") var profile: String
        @Option(help: "Days to look back (0 = all time).") var days = 30
        @Flag(help: "Include experiment trials.") var trials = false
        @Flag var json = false

        func run() async throws {
            let stats = try await global.client().ruleStats(profile, days: days, includeTrials: trials)
            if json { return try printJSON(stats) }
            print(stats.text)
        }
    }

    struct Test: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Try a profile's rules on a past tool result or some text, without a session.",
            discussion: """
                Shows which rules match and why the others don't. With --rewrite, also calls the rewrite agent once \
                (a small cost) and shows what Claude would see. Nothing is recorded.

                Examples:
                  diorama profiles test "Docs steer" --decision toolu_01abc
                  diorama profiles test "Docs steer" --text "Version 1 is the current API" --tool WebFetch --input '{"url":"https://example.com/docs"}' --rewrite
                  diorama profiles test --file draft.json --text-file page.txt
                """)
        @OptionGroup var global: GlobalOptions
        @Argument(help: "Saved profile name or id.") var profile: String?
        @Option(help: "A profile JSON file to test instead (e.g. an unsaved draft).") var file: String?
        @Option(help: "A session prompt to test as well (applies to every tool).") var prompt: String?
        @Option(help: "A past tool result to test on (tool_use_id, from `diorama session show`).") var decision: String?
        @Option(help: "Text to test on.") var text: String?
        @Option(help: "Read the text to test on from a file.") var textFile: String?
        @Option(help: "The tool the text comes from.") var tool: String = "WebFetch"
        @Option(help: "The tool input as JSON (rules can match on its fields).") var input: String?
        @Option(help: "Test the page stage (WebFetch raw page) instead of tool results.") var stage: RuleStage?
        @Flag(help: "Also run the rewrite agent (small cost).") var rewrite = false
        @Flag var json = false

        func run() async throws {
            var req = PlaygroundRequest(profileRef: profile, prompt: prompt.map { SessionPrompt(text: $0, tools: ["*"]) }, toolUseId: decision,
                                        toolName: tool, toolInput: input, stage: stage, rewrite: rewrite)
            if let file { req.profile = try readJSONFile(file, as: Profile.self) }
            if let textFile { req.text = try String(contentsOfFile: (textFile as NSString).expandingTildeInPath, encoding: .utf8) } else { req.text = text }
            guard req.profile != nil || profile != nil || prompt != nil else { throw ValidationError("give a profile, --file or --prompt") }
            guard decision != nil || req.text != nil else { throw ValidationError("give --decision, --text or --text-file") }
            let r = try await global.client().playground(req)
            if json { return try printJSON(r) }
            print("\(r.toolName) \(r.stage == .page ? "page" : "result"), \(r.originalText.count) characters")
            for c in r.checks { print("  \(c.matches ? "✓" : "·") \(c.name): \(c.reason)") }
            if let note = r.note { print("\n\(note)") }
            if let rw = r.rewrite {
                print("\nRewrite: \(rw.status.rawValue) — \(rw.model), \(Int(rw.latencyMs)) ms, \(money(rw.costUSD))")
                if let e = rw.explanation { print("  \(e)") }
                if let err = rw.error { print("  error: \(err)") }
                for e in rw.edits { print("  “\(short(e.find, 60))” → “\(short(e.replace, 60))”") }
                if let t = rw.replacementText { print("\nWhat Claude would see:\n\(t)") }
            } else if !rewrite, r.model != nil {
                print("\nAdd --rewrite to see what the rewrite agent (\(r.model!)) would do.")
            }
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
        static let configuration = CommandConfiguration(commandName: "set", abstract: "Set defaultModel, retentionDays, captureRawBodies, claudePath, ollamaURL or dailyBudgetUSD (none = no cap).")
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
            case "dailyBudgetUSD":
                if ["", "none", "off"].contains(value.lowercased()) { s.dailyBudgetUSD = nil } else {
                    guard let d = Double(value), d >= 0 else { throw ValidationError("dailyBudgetUSD must be a dollar amount, or none") }
                    s.dailyBudgetUSD = d
                }
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
            // Hook installs made before input rules existed miss the PreToolUse hook.
            let hookFolders = Set(try await c.sessions(limit: 200).filter(\.isHook).map(\.cwd))
            for folder in hookFolders.sorted() {
                let url = HookInstaller.projectSettings(folder)
                guard HookInstaller.installedCommand(settings: url) != nil else { continue }
                if !HookInstaller.installedEvents(settings: url).contains("PreToolUse") {
                    checks.append(DoctorCheck(name: "Hook", status: .warning, detail: "\(folder) has an older hook without input rules; run `diorama hook install` there again"))
                }
            }
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

// MARK: - update

struct Update: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check GitHub Releases for a newer Diorama (and optionally download it).")
    @Flag(help: "Download the latest release zip to ~/Downloads and verify its checksum.") var download = false
    @Option(help: .hidden) var assumeCurrent: String?
    @Option(help: .hidden) var directory: String?

    func run() async throws {
        let info = try await UpdateChecker.check(current: assumeCurrent ?? DioramaVersion.current)
        guard info.isNewer else { return print("Diorama \(info.current) is up to date (latest release: \(info.latest)).") }
        print("Diorama \(info.latest) is available (you have \(info.current)): \(info.pageURL)")
        guard download else { return print("Download it with: diorama update --download") }
        let target = directory.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let dest = try await UpdateChecker.download(info, to: target)
        print("Downloaded and verified \(dest.path).")
        print("To install: quit Diorama, run `diorama daemon stop`, unzip, replace /Applications/Diorama.app, then:")
        print("  xattr -dr com.apple.quarantine /Applications/Diorama.app")
    }
}

struct Spend: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show today's rewrite-agent spending against the daily caps.",
        discussion: """
            Caps: `diorama settings set dailyBudgetUSD 2` (all interactive rewrites, the playground and what-if), and \
            `defaults.dailyBudgetUSD` in a profile. When a cap is used up, matching tool results pass through unchanged \
            and the session is flagged. Experiment runs don't count: they run against their own approved estimate.
            """)
    @OptionGroup var global: GlobalOptions
    @Option(help: "Also show spending per day for the last N days (includes experiment trials).") var days: Int?
    @Flag var json = false

    func run() async throws {
        let client = try await global.client()
        if let days {
            let h = try await client.spendHistory(days: days)
            if json { return try printJSON(h) }
            print(SpendHistoryText.render(h))
            return
        }
        let s = try await client.spend()
        if json { return try printJSON(s) }
        let cap = s.dailyBudgetUSD.map { " of \(money($0)) daily budget" + (s.isOverBudget ? " — used up, rewrites paused" : "") } ?? " (no daily cap)"
        print("Today: \(money(s.todayUSD))\(cap)")
        for p in s.profiles {
            let pc = p.dailyBudgetUSD.map { " of \(money($0))" + (p.todayUSD >= $0 ? " — used up" : "") } ?? ""
            print("  \(p.name): \(money(p.todayUSD))\(pc)")
        }
    }
}

struct Search: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Search tool results, rewrites, tool inputs and Claude's replies across all sessions.",
        discussion: """
            All words must match; the last one also matches as a prefix. Results are best matches first.

            Examples:
              diorama search deprecated api
              diorama search "example.com" --rewritten
            """)
    @OptionGroup var global: GlobalOptions
    @Argument(parsing: .remaining, help: "Words to find.") var words: [String]
    @Flag(help: "Only results Diorama rewrote.") var rewritten = false
    @Option(help: "Only this session.") var session: String?
    @Option(help: "Maximum results.") var limit = 20
    @Flag var json = false

    func run() async throws {
        let hits = try await global.client().search(words.joined(separator: " "), rewrittenOnly: rewritten, sessionId: session, limit: limit)
        if json { return try printJSON(hits) }
        guard !hits.isEmpty else { return print("No matches.") }
        for h in hits {
            let what = h.kind == .reply ? "Claude's reply" : "\(h.toolName ?? "tool") \(h.outcome?.rawValue ?? "")"
            print("\(dateText(h.createdAt))  \(h.sessionName) (\(h.sessionId)) — \(what)  [\(h.ref)]")
            let snippet = h.snippet.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "⟦", with: "\u{1B}[1m").replacingOccurrences(of: "⟧", with: "\u{1B}[0m")
            print("    \(snippet)\n")
        }
    }
}

struct Folders: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Give project folders a default profile, used by `diorama run` there (and in folders below).",
        discussion: """
              diorama folders                              # list
              diorama folders set ~/code/app "Docs steer"
              diorama folders set . "Docs steer"
              diorama folders unset ~/code/app
            `diorama run --profile X` or `--prompt` still wins; `--no-folder-default` skips it.
            """,
        subcommands: [List.self, Set.self, Unset.self], defaultSubcommand: List.self)

    static func absolute(_ path: String) -> String {
        let p = (path as NSString).expandingTildeInPath
        return p.hasPrefix("/") ? p : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(p)
    }

    struct List: AsyncParsableCommand {
        @OptionGroup var global: GlobalOptions
        @Flag var json = false
        func run() async throws {
            let all = try await global.client().folderDefaults()
            if json { return try printJSON(all) }
            guard !all.isEmpty else { return print("No folder defaults. Set one with `diorama folders set <folder> <profile>`.") }
            for f in all { print("\(f.path)  →  \(f.profile ?? "")") }
        }
    }

    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Set a folder's default profile.")
        @OptionGroup var global: GlobalOptions
        @Argument var folder: String
        @Argument var profile: String
        func run() async throws {
            let f = try await global.client().setFolderDefault(Folders.absolute(folder), profile: profile)
            print("✓ Sessions started with `diorama run` in \(f.path) now use \(profile).")
        }
    }

    struct Unset: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove a folder's default profile.")
        @OptionGroup var global: GlobalOptions
        @Argument var folder: String
        func run() async throws {
            let f = try await global.client().setFolderDefault(Folders.absolute(folder), profile: nil)
            print("✓ \(f.path) has no default profile.")
        }
    }
}

struct ExportData: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export decided tool results as CSV or JSON Lines for analysis.",
        discussion: """
            One row per tool result Diorama decided: session, profile and version, tool and input, outcome and reason, \
            matching rules, rewrite attempts and cost, and sizes. --texts adds the original and rewritten text.
              diorama export --output decisions.csv
              diorama export --format jsonl --days 7 --profile "Docs steer" --rewritten-only --texts --output week.jsonl
            """)
    @OptionGroup var global: GlobalOptions
    @Option(help: "csv or jsonl.") var format: DataExport.Format = .csv
    @Option(help: "Only the last N days (0 = all time).") var days = 0
    @Option(help: "Only this session.") var session: String?
    @Option(help: "Only sessions that used this profile (name or id).") var profile: String?
    @Flag(help: "Leave out experiment trials.") var noTrials = false
    @Flag(help: "Only rewritten tool results.") var rewrittenOnly = false
    @Flag(help: "Include the original and rewritten text.") var texts = false
    @Option(help: "Write to a file instead of stdout.") var output: String?

    func run() async throws {
        let e = try await global.client().exportDecisions(format: format, days: days, sessionId: session, profile: profile,
                                                           includeTrials: !noTrials, rewrittenOnly: rewrittenOnly, includeTexts: texts)
        guard let output else { return print(e.content, terminator: "") }
        let url = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
        try e.content.write(to: url, atomically: true, encoding: .utf8)
        FileHandle.standardError.write(Data("✓ \(e.rows) row(s) written to \(url.path)\n".utf8))
    }
}

extension DataExport.Format: ExpressibleByArgument {}

struct Reviews: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "review",
        abstract: "List rewrites waiting for your approval (review mode), or approve or reject one.",
        discussion: """
            Profiles with review mode on hold each AI rewrite until you answer; Claude waits meanwhile. \
            Unanswered rewrites time out and Claude gets the original.
              diorama review                 # list what's waiting, with the proposed change
              diorama review approve toolu_01abc
              diorama review reject toolu_01abc
            """)
    @OptionGroup var global: GlobalOptions
    @Argument(help: "approve or reject.") var action: String?
    @Argument(help: "The review's id (from the list).") var id: String?
    @Flag var json = false

    func run() async throws {
        let client = try await global.client()
        switch action {
        case nil:
            let pending = try await client.pendingReviews()
            if json { return try printJSON(pending) }
            guard !pending.isEmpty else { return print("Nothing is waiting for review.") }
            for r in pending {
                print("\(r.id)  \(r.toolName) in “\(r.sessionName)”, \(max(0, Int(r.expiresAt.timeIntervalSinceNow))) s left")
                print("  \(r.explanation)")
                print("  " + TextDiff.inline(TextDiff.diff(r.originalText, r.proposedText)).prefix(2000).replacingOccurrences(of: "\n", with: "\n  "))
            }
        case "approve", "reject":
            guard let id else { throw ValidationError("give the review's id") }
            try await client.resolveReview(id, approve: action == "approve")
            print(action == "approve" ? "✓ Approved: Claude gets the rewrite." : "✗ Rejected: Claude gets the original.")
        default:
            throw ValidationError("unknown action '\(action!)': use approve or reject")
        }
    }
}

struct PauseAll: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pause",
        abstract: "Pause steering everywhere: no AI rewrites or input changes in any session until `diorama resume` (redaction keeps working; experiment runs are not affected).")
    @OptionGroup var global: GlobalOptions
    func run() async throws {
        _ = try await global.client().setSteeringPaused(true)
        print("⏸ Steering paused everywhere. Resume with `diorama resume`.")
    }
}

struct ResumeAll: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "resume", abstract: "Resume steering everywhere.")
    @OptionGroup var global: GlobalOptions
    func run() async throws {
        _ = try await global.client().setSteeringPaused(false)
        print("▶ Steering resumed.")
    }
}
