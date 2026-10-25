import DioramaCore
import DioramaJSON
import DioramaEngine
import DioramaRunner
import DioramaStore
import Darwin
import Foundation

/// The background service: gateway + control API + rewrite engine + experiment runner.
public final class DioramaDaemon: @unchecked Sendable {
    public enum ProviderKind: String, Sendable {
        /// Anthropic Messages API with the user's key (production).
        case anthropic
        /// Offline: always answers "unchanged" (demos, smoke tests). Never makes network calls.
        case offline
    }

    public struct Options: Sendable {
        public var paths: DioramaPaths
        public var port: Int = 47821
        public var exactPort = false
        public var upstream = URL(string: "https://api.anthropic.com")!
        public var rewriteBaseURL = URL(string: "https://api.anthropic.com")!
        public var provider: ProviderKind = .anthropic
        public var secrets: SecretStore?
        public var maxBodyBytes = 128 * 1024 * 1024
        public var writeDaemonInfo = true
        public var environment = ProcessInfo.processInfo.environment
        /// Overrides the provider entirely (tests).
        public var providerOverride: RewriteProvider?
        /// The `diorama` CLI that input-rule hooks run (default: next to this executable).
        public var cliPath: String?
        /// Overrides the LLM judge (tests).
        public var judgeOverride: JudgeProvider?

        public init(paths: DioramaPaths) { self.paths = paths }
    }

    public let options: Options
    public let store: Store
    let engine: DecisionEngine
    let upstream = UpstreamClient()
    let hub = EventHub()
    let sessions: SessionCache
    public let runner: ExperimentRunner
    let secrets: SecretStore
    let server: HTTPServer
    public let controlToken = Hashing.randomToken()
    public private(set) var port = 0
    let startedAt = Date()
    private var lockFD: Int32 = -1
    private var background: [Task<Void, Never>] = []
    private let stopLock = NSLock()
    private var stopTask: Task<Void, Never>?

    public init(options: Options) throws {
        self.options = options
        try options.paths.ensureDirectories()
        // Take the single-instance lock before touching the database: a second daemon that
        // opened it first could race the first one's migrations, or mistake a busy database
        // for a corrupt one and move it aside.
        if options.writeDaemonInfo {
            let fd = open(options.paths.daemonLock.path, O_CREAT | O_RDWR, 0o600)
            guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                if fd >= 0 { close(fd) }
                throw RunnerError("another Diorama daemon is already running for \(options.paths.home.path)")
            }
            lockFD = fd
        }
        do {
            store = try Store(paths: options.paths)
        } catch {
            if lockFD >= 0 { close(lockFD) }
            throw error
        }
        sessions = SessionCache(store: store)
        let secrets = options.secrets ?? LayeredSecretStore(override: EnvironmentSecretStore(environment: options.environment), primary: KeychainSecretStore())
        self.secrets = secrets
        let store = self.store
        let ollama = OllamaRewriteProvider(baseURL: { URL(string: store.settings().ollamaURL) ?? URL(string: DioramaSettings.defaultOllamaURL)! })
        let provider: RewriteProvider
        if let o = options.providerOverride {
            provider = o
        } else {
            switch options.provider {
            case .anthropic:
                provider = AnthropicRewriteProvider(baseURL: options.rewriteBaseURL, apiKey: { secrets.get() })
            case .offline:
                provider = ScriptedRewriteProvider(id: "offline") { _ in
                    RewriteResponse(status: .unchanged, output: RewriteOutput(decision: .unchanged, explanation: "offline provider: no rewrite performed"), modelServed: "offline")
                }
            }
        }
        let routesOllama = options.providerOverride == nil && options.provider == .anthropic
        engine = DecisionEngine(store: store) { (model: String) in
            routesOllama && OllamaRewriteProvider.isOllama(model) ? ollama : provider
        }
        server = HTTPServer(maxBodyBytes: options.maxBodyBytes)
        let factory = SessionFactoryBox()
        runner = ExperimentRunner(
            store: store, paths: options.paths, environment: options.environment,
            claudePath: { [store] in ClaudeLocator.find(configured: store.settings().claudePath, environment: options.environment) },
            judge: options.judgeOverride ?? RoutingJudge(anthropic: AnthropicJudge(baseURL: options.rewriteBaseURL, apiKey: { secrets.get() }), ollama: ollama),
            makeSession: { spec in
                guard let make = factory.make else { throw RunnerError("daemon is shutting down") }
                return try make(spec)
            })
        factory.make = { [unowned self] spec in try self.createSession(spec) }
        store.onEvent = { [hub] ev in hub.publish(ev) }
    }

    // MARK: Lifecycle

    /// Binds the port and writes `daemon.json` (the single-instance lock is taken in `init`).
    public func start() async throws -> Int {
        port = try await server.bind(port: options.port, exactPort: options.exactPort)
        if options.writeDaemonInfo {
            try DaemonInfo(pid: getpid(), port: port, controlToken: controlToken, version: DioramaVersion.current, startedAt: startedAt)
                .write(to: options.paths.daemonInfo)
        }
        let recovered = (try? store.recoverInterruptedRuns()) ?? 0
        if recovered > 0 { store.addEvent(sessionId: nil, kind: .warning, message: "Marked \(recovered) interrupted experiment run(s) as failed") }
        if let note = store.recoveryNote { store.addEvent(sessionId: nil, kind: .warning, message: note) }
        // Search: index decisions and replies as they happen, and whatever earlier versions didn't.
        let (_, events) = hub.subscribe()
        background.append(Task { [store] in
            for await ev in events {
                switch ev.kind {
                case .decisionMade, .rewriteFailed: if let ref = ev.refId { Self.indexDecision(ref, store: store) }
                case .exchangeFinished: if let ref = ev.refId, let id = Int64(ref) { Self.indexReply(id, store: store) }
                default: break
                }
            }
        })
        background.append(Task.detached(priority: .utility) { [store] in Self.backfillSearch(store: store) })
        background.append(Task { [store] in
            while !Task.isCancelled {
                _ = try? store.applyRetention(days: store.settings().retentionDays)
                try? await Task.sleep(for: .seconds(24 * 3600))
            }
        })
        // Profile folders: pick up new and changed profile files.
        background.append(Task.detached(priority: .utility) { [store] in
            while !Task.isCancelled {
                let folders = store.settings().profileFolders
                if !folders.isEmpty { store.syncProfileFolders(folders) }
                try? await Task.sleep(for: .seconds(5))
            }
        })
        background.append(Task { [hub] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                hub.publish(SessionEvent(id: -1, sessionId: nil, kind: .warning, message: "heartbeat", refId: nil, createdAt: Date()))
            }
        })
        return port
    }

    /// Serves until `stop()`.
    public func run() async throws {
        try await server.serve(Router(daemon: self))
    }

    /// Idempotent: every caller awaits the same single shutdown, so nobody (for example the
    /// main path after `run()` returns) can exit the process while cleanup is still running.
    public func stop() async {
        let task = stopLock.withLock { () -> Task<Void, Never> in
            if let t = stopTask { return t }
            let t = Task { await self.performStop() }
            stopTask = t
            return t
        }
        await task.value
    }

    private func performStop() async {
        for id in runner.activeRunIds { try? runner.cancel(runId: id) }
        for t in background { t.cancel() }
        await engine.reviews.expireAll()
        hub.finishAll()
        await server.shutdown()
        upstream.invalidate()
        if options.writeDaemonInfo {
            if let info = DaemonInfo.read(from: options.paths.daemonInfo), info.pid == getpid() {
                try? FileManager.default.removeItem(at: options.paths.daemonInfo)
            }
            if lockFD >= 0 {
                flock(lockFD, LOCK_UN)
                close(lockFD)
                lockFD = -1
            }
        }
    }

    // MARK: Operations

    public var baseURL: String { "http://127.0.0.1:\(port)" }

    func createSession(_ spec: SessionSpec) throws -> SessionLaunch {
        var spec = spec
        spec.cwd = (spec.cwd as NSString).expandingTildeInPath
        if spec.name.trimmingCharacters(in: .whitespaces).isEmpty { spec.name = (spec.cwd as NSString).lastPathComponent }
        let token = Hashing.randomToken()
        let record = try store.createSession(spec, tokenHash: Hashing.sha256Hex(token))
        let base = "\(baseURL)/s/\(token)"
        // DIORAMA_SESSION tells an installed Diorama hook that the gateway already handles this session.
        let env = ["ANTHROPIC_BASE_URL": base, "CLAUDE_CODE_GATEWAY_HINT_HEADERS": "1", "DIORAMA_SESSION": record.id]
        // Passing the same env through --settings makes it win over an `env` block in the user's
        // own settings files (settings beat shell exports), without changing any file on disk.
        var settings: [String: Any] = ["env": env]
        let deny = spec.lockdown.disallowedTools
        if !deny.isEmpty { settings["permissions"] = ["deny": deny] }
        // Input rules act before a tool runs, which only a PreToolUse hook can do: add one for this session.
        // Not for experiment trials, whose tool calls can't be approved interactively.
        let hasInputRules = (record.profileVersion?.profile.rules ?? []).contains { $0.enabled && $0.match.stage == .input } || spec.prompt?.stage == .input
        if hasInputRules, spec.kind == .interactive {
            if let cli = options.cliPath ?? Self.bundledCLI() {
                let command = "'" + cli.replacingOccurrences(of: "'", with: "'\\''") + "' hook run"
                settings["hooks"] = ["PreToolUse": [["matcher": "*", "hooks": [["type": "command", "command": command, "timeout": 180]]]]]
            } else {
                store.addEvent(sessionId: record.id, kind: .warning, message: "Input rules can't apply: the diorama CLI wasn't found next to the daemon", refId: record.id)
            }
        }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        return SessionLaunch(session: try store.info(record), token: token, baseURL: base, environment: env, claudeArguments: ["--settings", json])
    }

    // MARK: Search index

    static func indexDecision(_ id: String, store: Store) {
        guard !store.isIndexed(kind: .decision, ref: id), let d = try? store.decision(toolUseId: id) else { return }
        let via = ((try? store.session(id: d.sessionId)) ?? nil)?.via ?? .gateway
        let rewritten = d.replacementBlob.map { blob -> String in
            var copy = d
            copy.originalBlob = blob
            return readableSegments(copy, via: via, store: store).joined(separator: "\n\n")
        }
        store.index(kind: .decision, ref: id, sessionId: d.sessionId, createdAt: d.createdAt, outcome: d.outcome, tool: d.toolName, input: d.toolInput,
                    original: readableSegments(d, via: via, store: store).joined(separator: "\n\n"), rewritten: rewritten, note: d.reason)
    }

    static func indexReply(_ exchangeId: Int64, store: Store) {
        guard let e = (try? store.exchange(id: exchangeId)) ?? nil, let a = e.assistant, !(a.text.isEmpty && a.toolUses.isEmpty) else { return }
        store.index(kind: .reply, ref: String(exchangeId), sessionId: e.sessionId, createdAt: e.startedAt, outcome: nil,
                    tool: a.toolUses.map(\.name).joined(separator: " "), input: a.toolUses.map(\.input).joined(separator: "\n"),
                    original: a.text, rewritten: nil, note: nil)
    }

    /// Indexes everything recorded before search existed (or missed while the daemon was busy).
    static func backfillSearch(store: Store) {
        while !Task.isCancelled, let batch = try? store.unindexed(limit: 200), !(batch.decisions.isEmpty && batch.exchanges.isEmpty) {
            for id in batch.decisions { indexDecision(id, store: store) }
            for id in batch.exchanges { indexReply(id, store: store) }
            // Anything that can't be indexed (e.g. a missing blob) is marked so the loop ends.
            for id in batch.decisions where !store.isIndexed(kind: .decision, ref: id) { store.markIndexed(kind: .decision, ref: id) }
            for id in batch.exchanges where !store.isIndexed(kind: .reply, ref: String(id)) { store.markIndexed(kind: .reply, ref: String(id)) }
        }
    }

    // MARK: Session → experiment

    /// Prefills an experiment from a session: its task (first prompt), project, tools and model,
    /// with an unmodified control and the session's steering (pinned to the version it used).
    func experimentDraft(sessionId: String, trialsPerVariant: Int = 5) throws -> ExperimentDraft {
        guard let session = try store.session(id: sessionId) else { throw StoreError("no session \(sessionId)") }
        guard session.kind == .interactive else { throw StoreError("this session is already an experiment trial") }
        var notes: [String] = []
        let exchanges = try store.exchanges(sessionId: session.id)
        let mains = exchanges.filter { $0.method == "POST" && $0.path == "/v1/messages" && ($0.requestClass == "main" || $0.requestClass == nil) }

        // The task: the session's first prompt.
        var task: String?
        if session.via == .hook {
            task = session.transcriptPath.flatMap(Self.firstUserMessage)
        } else if let first = mains.first, let raw = try store.exchangeRaw(id: first.id)?.request {
            task = (try? ScannedRequest.scan(Array(raw.utf8)))?.taskText
        }
        task = task?.trimmingCharacters(in: .whitespacesAndNewlines)
        if task?.isEmpty ?? true {
            notes.append("The session's first prompt wasn't recorded (raw capture off, or an older session). Write the task before creating.")
        } else {
            notes.append("The task is the session's first prompt. Experiments run it with `claude -p`, so make sure it works without follow-up questions.")
        }

        // Tools and model, from what the session actually used.
        var tools = Set(try store.decisions(sessionId: session.id).compactMap { $0.toolName?.replacingOccurrences(of: " (page)", with: "") })
        for e in exchanges { for u in e.assistant?.toolUses ?? [] { tools.insert(u.name) } }
        var allowed = tools.sorted()
        if allowed.isEmpty {
            allowed = ["WebFetch", "WebSearch", "Read"]
            notes.append("No tool calls were recorded; allowed tools default to WebFetch, WebSearch and Read.")
        }
        let usesMCP = allowed.contains { $0.hasPrefix("mcp__") }
        if usesMCP { notes.append("The session used MCP tools, so trials use your Claude Code configuration (not isolated) to have them.") }
        let models = mains.compactMap(\.model)
        let model = Dictionary(grouping: models, by: { $0 }).max { $0.value.count < $1.value.count }?.key
        let turns = session.via == .hook ? (try store.decisions(sessionId: session.id).count) : mains.count
        let maxTurns = max(10, min(50, turns * 2))

        // Variants: an unmodified control, and the session's steering.
        var steered = ExperimentVariant(key: "steered", name: "Steered")
        if let v = session.profileVersion {
            steered.profile = v.id
            steered.name = "\(v.profile.name) v\(v.number)"
            if let current = try store.resolveProfile(v.profileId), current.id != v.id {
                notes.append("Pinned to v\(v.number) of “\(v.profile.name)”, the version this session used (the current one is v\(current.number)).")
            }
        }
        if let p = session.prompt {
            steered.prompt = p
            if session.profileVersion == nil { steered.name = "Session prompt" }
        }
        if steered.isControl {
            notes.append("This session had no profile or prompt. Add the steering to compare in the steered variant.")
            steered.prompt = SessionPrompt(text: "")
        }
        if session.lockdown != .none { steered.lockdown = session.lockdown }

        let definition = ExperimentDefinition(
            name: "\(session.name) — experiment", task: task ?? "", projectPath: session.cwd,
            claude: ClaudeRunOptions(model: model, allowedTools: allowed, maxTurns: maxTurns, maxBudgetUSD: 2, isolateConfiguration: !usesMCP),
            variants: [ExperimentVariant(key: "control", name: "Unmodified"), steered],
            trialsPerVariant: max(1, min(trialsPerVariant, 200)), concurrency: 2)
        notes.append("Trials run in copies of \(session.cwd); the folder itself is never changed. Review the trial count, then estimate the cost before running.")
        return ExperimentDraft(definition: definition, notes: notes)
    }

    // MARK: Budget

    func spendSummary() throws -> SpendSummary {
        let start = Calendar.current.startOfDay(for: Date())
        let byProfile = store.spendByProfile(since: start)
        let profiles = try store.profiles().compactMap { p -> SpendSummary.ProfileSpend? in
            let budget = try store.resolveProfile(p.id)?.profile.defaults.dailyBudgetUSD
            let today = byProfile[p.id] ?? 0
            guard today > 0 || budget != nil else { return nil }
            return SpendSummary.ProfileSpend(profileId: p.id, name: p.name, todayUSD: today, dailyBudgetUSD: budget)
        }
        return SpendSummary(since: start, todayUSD: store.spend(since: start), dailyBudgetUSD: store.settings().dailyBudgetUSD, profiles: profiles)
    }

    // MARK: Rule playground

    func playground(_ req: PlaygroundRequest) async throws -> PlaygroundResult {
        var profile = req.profile
        var profileId: String?
        if profile == nil, let ref = req.profileRef, !ref.isEmpty {
            guard let v = try store.resolveProfile(ref) else { throw StoreError("unknown profile '\(ref)'") }
            profile = v.profile
            profileId = v.profileId
        }
        let rules = (profile?.rules ?? []) + (req.prompt.map { [$0.asRule(id: "session-prompt")] } ?? [])
        guard !rules.isEmpty else { throw StoreError("give a profile or a prompt to test") }
        let defaults = profile?.defaults ?? ProfileDefaults(model: store.settings().defaultModel)
        if req.rewrite, let why = engine.budgetBlock(profileId: profileId, profileBudget: defaults.dailyBudgetUSD) {
            throw StoreError("rewrite budget reached: \(why). Raise it in Settings or the profile's defaults, or wait until tomorrow")
        }
        // What to run on: a recorded tool result or pasted text.
        let toolName: String, input: String?, segments: [String], isError: Bool, stage: RuleStage, sampleId: String?
        if let id = req.toolUseId, !id.isEmpty {
            guard let d = try store.decision(toolUseId: id) else { throw StoreError("no tool result \(id)") }
            let session = try store.session(id: d.sessionId)
            (toolName, input) = ((d.toolName ?? "tool").replacingOccurrences(of: " (page)", with: ""), d.toolInput)
            (segments, isError, stage, sampleId) = (playgroundSegments(d, via: session?.via ?? .gateway), d.isError, req.stage ?? Self.stage(ofDecision: id), d.toolUseId)
        } else {
            guard let text = req.text, !text.isEmpty else { throw StoreError("give a past tool result (toolUseId) or text to test on") }
            (toolName, input) = (req.toolName.flatMap { $0.isEmpty ? nil : $0 } ?? "WebFetch", req.toolInput)
            (segments, isError, stage, sampleId) = ([text], false, req.stage ?? .result, nil)
        }
        let (engine, spendProfile) = (self.engine, profileId)
        let run: @Sendable (String?) async -> PlaygroundResult = { model in
            await engine.playground(rules: rules, defaults: defaults, toolName: toolName, toolInputJSON: input, segments: segments, isError: isError,
                                    stage: stage, rewrite: req.rewrite, profileId: spendProfile, sampleId: sampleId, modelOverride: model)
        }
        var models: [String] = []
        for m in (req.models ?? []).map({ $0.trimmingCharacters(in: .whitespaces) }) where !m.isEmpty && !models.contains(m) { models.append(m) }
        guard req.rewrite, !models.isEmpty else { return await run(nil) }
        guard models.count <= PlaygroundRequest.maxComparedModels else { throw StoreError("compare at most \(PlaygroundRequest.maxComparedModels) models at a time") }
        // Model comparison: the same rewrite on each model, concurrently.
        let results = await withTaskGroup(of: (Int, PlaygroundResult).self) { group in
            for (i, m) in models.enumerated() { group.addTask { (i, await run(m)) } }
            var out: [(Int, PlaygroundResult)] = []
            for await r in group { out.append(r) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
        var first = results[0]
        if results.contains(where: { $0.rewrite != nil }) {
            // Labeled by the model asked for (the served id can carry a date suffix or a fallback).
            first.comparisons = zip(models, results).map { m, r in
                var rw = r.rewrite ?? PlaygroundRewrite(status: .skipped, replacementText: nil, explanation: nil, edits: [], error: r.note, model: m, costUSD: nil, latencyMs: 0)
                if rw.model != m, rw.model != "local redaction" { rw.model = m }
                return rw
            }
            first.rewrite = first.comparisons?.first
        }
        return first
    }

    // MARK: What-if replay

    func whatIf(_ req: WhatIfRequest) async throws -> WhatIfResult {
        guard let session = try store.session(id: req.sessionId) else { throw StoreError("no session \(req.sessionId)") }
        var profile = req.profile
        var profileId: String?
        var label = profile.map { "“\($0.name)” (draft)" }
        if profile == nil, let vid = req.profileVersionId, !vid.isEmpty {
            guard let v = try store.profileVersion(id: vid) else { throw StoreError("no profile version \(vid)") }
            profile = v.profile
            profileId = v.profileId
            label = "“\(v.profile.name)” v\(v.number)"
        } else if profile == nil, let ref = req.profileRef, !ref.isEmpty {
            guard let v = try store.resolveProfile(ref) else { throw StoreError("unknown profile '\(ref)'") }
            profile = v.profile
            profileId = v.profileId
            label = "“\(v.profile.name)” v\(v.number)"
        }
        if req.prompt != nil { label = (label.map { $0 + " + " } ?? "") + "session prompt" }
        let rules = (profile?.rules ?? []) + (req.prompt.map { [$0.asRule(id: "session-prompt")] } ?? [])
        guard !rules.isEmpty else { throw StoreError("give a profile, a profile version or a prompt to compare with") }
        let defaults = profile?.defaults ?? ProfileDefaults(model: store.settings().defaultModel)
        let limit = min(max(req.maxRewrites ?? 25, 0), 60)

        struct Source: Sendable {
            var decision: DecisionRecord
            var toolName: String
            var stage: RuleStage
            var segments: [String]
            var beforeText: String?
        }
        let sources: [Source] = try store.decisions(sessionId: session.id).sorted { $0.createdAt < $1.createdAt }.compactMap { d in
            let segments = playgroundSegments(d, via: session.via)
            guard !segments.joined().isEmpty else { return nil }
            // The session's rewrite, read the same way as the original so the texts compare like for like.
            let before: String? = d.replacementBlob.map { blob in
                var copy = d
                copy.originalBlob = blob
                return playgroundSegments(copy, via: session.via).joined(separator: "\n\n")
            }
            return Source(decision: d, toolName: (d.toolName ?? "tool").replacingOccurrences(of: " (page)", with: ""),
                          stage: Self.stage(ofDecision: d.toolUseId), segments: segments, beforeText: before)
        }

        // Free pass: which rules match each result.
        var checked: [(Source, PlaygroundResult)] = []
        for src in sources {
            let r = await engine.playground(rules: rules, defaults: defaults, toolName: src.toolName, toolInputJSON: src.decision.toolInput,
                                            segments: src.segments, isError: src.decision.isError, stage: src.stage, rewrite: false,
                                            sampleId: src.decision.toolUseId)
            checked.append((src, r))
        }
        let matchedIndices = checked.indices.filter { checked[$0].1.model != nil }
        let toRun = Array(matchedIndices.prefix(limit))
        var (low, high) = (0.0, 0.0)
        for i in toRun {
            let (lo, hi) = Self.rewriteEstimate(chars: checked[i].1.originalText.count, model: checked[i].1.model ?? defaults.model, maxOutput: defaults.maxOutputTokens)
            low += lo
            high += hi
        }

        if req.rewrite, !toRun.isEmpty {
            if let why = engine.budgetBlock(profileId: profileId, profileBudget: defaults.dailyBudgetUSD) {
                throw StoreError("rewrite budget reached: \(why). Raise it in Settings or the profile's defaults, or wait until tomorrow")
            }
            if let left = engine.remainingBudget(profileId: profileId, profileBudget: defaults.dailyBudgetUSD), low > left {
                throw StoreError(String(format: "this run (about $%.3f–$%.3f) would go over today's remaining rewrite budget ($%.3f); lower max_rewrites or raise the budget", low, high, left))
            }
        }

        // Rewrites, at most four at a time, when asked for.
        let spendProfile = profileId
        var rewritten: [Int: PlaygroundRewrite] = [:]
        if req.rewrite, !toRun.isEmpty {
            rewritten = await withTaskGroup(of: (Int, PlaygroundRewrite?).self) { group in
                var results: [Int: PlaygroundRewrite] = [:]
                var next = 0
                func add(_ g: inout TaskGroup<(Int, PlaygroundRewrite?)>) {
                    guard next < toRun.count else { return }
                    let i = toRun[next]
                    next += 1
                    let src = checked[i].0
                    g.addTask {
                        let r = await self.engine.playground(rules: rules, defaults: defaults, toolName: src.toolName, toolInputJSON: src.decision.toolInput,
                                                             segments: src.segments, isError: src.decision.isError, stage: src.stage, rewrite: true,
                                                             spendKind: "whatif", profileId: spendProfile, sampleId: src.decision.toolUseId)
                        return (i, r.rewrite)
                    }
                }
                for _ in 0..<4 { add(&group) }
                while let (i, r) = await group.next() {
                    if let r { results[i] = r }
                    add(&group)
                }
                return results
            }
        }

        var items: [WhatIfItem] = []
        var cost = 0.0
        for (i, (src, check)) in checked.enumerated() {
            let d = src.decision
            let wasRewritten = d.outcome == .rewritten
            var item = WhatIfItem(
                toolUseId: d.toolUseId, toolName: src.toolName, toolInput: d.toolInput, originalText: check.originalText, before: d.outcome,
                beforeReason: d.reason, beforeText: src.beforeText, matchedRules: check.checks.filter(\.matches).map(\.name), change: .sameUnchanged)
            // Rules that only redact are applied by the check itself (local, free).
            let local = check.model == nil ? check.rewrite : nil
            if check.model == nil, local?.replacementText == nil {
                item.change = wasRewritten ? .noLongerRewritten : .sameUnchanged
            } else if check.model != nil, !req.rewrite {
                item.change = .wouldRewrite
            } else if let r = local ?? rewritten[i] {
                item.costUSD = r.costUSD
                cost += r.costUSD ?? 0
                item.afterExplanation = r.explanation
                item.afterError = r.error
                switch r.status {
                case .succeeded:
                    item.afterText = r.replacementText
                    item.change = !wasRewritten ? .nowRewritten : (r.replacementText == src.beforeText ? .sameRewrite : .rewrittenDifferently)
                case .unchanged:
                    item.change = wasRewritten ? .noLongerRewritten : .sameUnchanged
                default:
                    item.change = .failed
                }
            } else {
                item.change = .skipped
            }
            items.append(item)
        }
        return WhatIfResult(
            sessionId: session.id, sessionName: session.name, rulesLabel: label ?? "session prompt", rewrite: req.rewrite, items: items,
            calls: toRun.count, estimateLowUSD: low, estimateHighUSD: high, costUSD: cost)
    }

    /// A rough per-call cost range: the instructions plus the content in, a short edit list (low) up to a full replacement (high) out.
    static func rewriteEstimate(chars: Int, model: String, maxOutput: Int) -> (Double, Double) {
        guard let p = Pricing.price(for: model), !model.hasPrefix("ollama:") else { return (0, 0) }
        let input = Double(chars / 4 + 1200)
        let low = (input * p.input + 200 * p.output) / 1_000_000
        let high = (input * p.input + Double(min(chars / 3 + 200, maxOutput)) * p.output) / 1_000_000
        return (low, high)
    }

    /// A rule test from a recorded tool result, expecting the rules of `profile` that match it now.
    /// Its id is the tool result's id, so sampled rules sample it as the session did, and adding
    /// the same result again replaces the earlier test.
    func ruleTest(fromDecision id: String, profile: Profile, name: String?) throws -> ProfileTestCase {
        guard let d = try store.decision(toolUseId: id) else { throw StoreError("no tool result \(id)") }
        let via = try store.session(id: d.sessionId)?.via ?? .gateway
        let tool = (d.toolName ?? "tool").replacingOccurrences(of: " (page)", with: "")
        var t = ProfileTestCase(id: id, name: name ?? Self.testName(tool: tool, input: d.toolInput), toolName: tool, toolInput: d.toolInput,
                                text: playgroundSegments(d, via: via).joined(separator: "\n\n"), stage: Self.stage(ofDecision: id), isError: d.isError, expectMatch: [])
        let matched = Set(ProfileTests.run(t, rules: profile.rules).matched)
        t.expectMatch = profile.rules.filter { matched.contains($0.name) }.map(\.id)
        return t
    }

    /// Impact of each rewritten result in a session (see `ImpactAnalysis`).
    func impact(sessionId: String) throws -> [DecisionImpact] { try Self.impact(sessionId: sessionId, store: store) }

    static func impact(sessionId: String, store: Store) throws -> [DecisionImpact] {
        guard let s = try store.session(id: sessionId) else { throw StoreError("no session \(sessionId)") }
        let info = try store.info(s)
        let timeline = Timeline(session: info, exchanges: try store.exchanges(sessionId: sessionId),
                                decisions: try store.decisions(sessionId: sessionId).map(\.summary), events: [])
        let outputs = ImpactAnalysis.outputs(timeline)
        return try store.decisions(sessionId: sessionId).filter { $0.outcome == .rewritten && !$0.toolUseId.hasPrefix("input:") }.map { d in
            let original = Self.readableSegments(d, via: s.via, store: store).joined(separator: "\n\n")
            var copy = d
            copy.originalBlob = d.replacementBlob ?? d.originalBlob
            let replacement = Self.readableSegments(copy, via: s.via, store: store).joined(separator: "\n\n")
            return ImpactAnalysis.analyze(
                ImpactAnalysis.Rewrite(toolUseId: d.toolUseId, exchangeId: d.exchangeId, decidedAt: d.createdAt, toolName: d.toolName,
                                       toolInput: d.toolInput, original: original, replacement: replacement),
                outputs: outputs, repliesVisible: !info.isHook)
        }
    }

    static func testName(tool: String, input: String?) -> String {
        guard let data = input?.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return tool }
        for key in ["url", "query", "file_path", "command", "pattern"] {
            if let v = obj[key] as? String, !v.isEmpty { return "\(tool) \(v.count > 60 ? String(v.prefix(60)) + "…" : v)" }
        }
        return tool
    }

    static func stage(ofDecision id: String) -> RuleStage {
        id.hasPrefix("page:") ? .page : id.hasPrefix("input:") ? .input : .result
    }

    /// The readable text of a recorded original, split the way the engine split it.
    func playgroundSegments(_ d: DecisionRecord, via: SessionVia) -> [String] { Self.readableSegments(d, via: via, store: store) }

    static func readableSegments(_ d: DecisionRecord, via: SessionVia, store: Store) -> [String] {
        let original = (try? store.blobs.get(d.originalBlob)) ?? []
        if d.toolUseId.hasPrefix("input:") { return [DecisionEngine.prettyJSON(original) ?? String(decoding: original, as: UTF8.self)] }
        guard let v = try? JSONValue.parse(original) else { return [String(decoding: original, as: UTF8.self)] }
        if via == .hook {
            return HookOutputMapping.textPaths(toolName: d.toolName ?? "", response: v).compactMap { HookOutputMapping.get(v, $0)?.stringValue }
        }
        switch v {
        case .string(let s): return [s]
        case .array(let items):
            return items.compactMap { item in
                guard case .object(let o) = item, o["type"]?.stringValue == "text" else { return nil }
                return o["text"]?.stringValue
            }
        default: return [String(decoding: original, as: UTF8.self)]
        }
    }

    // MARK: Hook mode

    /// Handles one Claude Code hook event (hook mode: Claude desktop, IDEs). Sessions are keyed
    /// by Claude's session id; their configuration is fixed when the first event arrives.
    func handleHook(_ e: HookEvent) async throws -> HookReply {
        guard !e.claudeSessionId.isEmpty else { throw RunnerError("hook event without a session id") }
        // A `diorama run` session: the gateway handles its results; the hook only carries tool inputs.
        if let gid = e.dioramaSessionId {
            guard e.event == "PreToolUse", let session = try store.session(id: gid), session.kind == .interactive else { return HookReply() }
            return await decideInput(e, session: session)
        }
        guard let session = try hookSession(e) else { return HookReply() }
        if e.event == "PreToolUse" { return await decideInput(e, session: session) }
        if let path = e.transcriptPath, session.transcriptPath != path { try? store.setTranscriptPath(sessionId: session.id, path) }
        switch e.event {
        case "SessionEnd":
            try store.endSession(id: session.id)
            return HookReply(sessionId: session.id)
        case "PostToolUse":
            guard let tool = e.toolName, let toolUseId = e.toolUseId, let response = e.toolResponse else { return HookReply(sessionId: session.id) }
            let task = wantsTaskContext(session) ? e.transcriptPath.flatMap(Self.firstUserMessage) : nil
            let (d, output) = await engine.decideHook(
                session: session, toolUseId: toolUseId, toolName: tool, toolInputJSON: e.toolInput, responseJSON: response, taskText: task)
            return HookReply(sessionId: session.id, updatedToolOutput: output.map { String(decoding: $0, as: UTF8.self) }, outcome: d?.outcome, reason: d?.reason)
        default:
            return HookReply(sessionId: session.id)
        }
    }

    func decideInput(_ e: HookEvent, session: SessionRecord) async -> HookReply {
        guard let tool = e.toolName, let toolUseId = e.toolUseId, let input = e.toolInput else { return HookReply(sessionId: session.id) }
        let task = wantsTaskContext(session) ? (e.transcriptPath ?? session.transcriptPath).flatMap(Self.firstUserMessage) : nil
        let (d, output) = await engine.decideInput(session: session, toolUseId: toolUseId, toolName: tool, toolInputJSON: input, taskText: task)
        return HookReply(sessionId: session.id, updatedInput: output.map { String(decoding: $0, as: UTF8.self) }, outcome: d?.outcome, reason: d?.reason)
    }

    private let hookLock = NSLock()

    /// Finds the session for a Claude session id, creating it on first contact. A resumed
    /// Claude session (same id) reopens its Diorama session.
    func hookSession(_ e: HookEvent) throws -> SessionRecord? {
        // Not a SHA-256 hex digest, so no gateway URL token can ever map to a hook session.
        let key = "hook:" + Hashing.sha256Hex(e.claudeSessionId)
        return try hookLock.withLock {
            if let existing = try store.session(tokenHash: key) {
                if existing.status == .ended, e.event != "SessionEnd" {
                    try store.reopenSession(id: existing.id)
                    return try store.session(id: existing.id)
                }
                return existing
            }
            if e.event == "SessionEnd" { return nil }
            let cwd = (e.cwd as NSString).expandingTildeInPath
            let folder = (cwd as NSString).lastPathComponent
            let name = e.client == "claude-desktop" ? "\(folder) · Desktop" : folder
            var spec = SessionSpec(name: name, cwd: cwd, profile: e.config.profile, prompt: e.config.prompt, via: .hook)
            let record: SessionRecord
            do {
                record = try store.createSession(spec, tokenHash: key)
            } catch let err as StoreError {
                // A bad hook configuration must not break the session: record it and apply nothing.
                spec.profile = nil
                spec.prompt = nil
                record = try store.createSession(spec, tokenHash: key)
                store.addEvent(sessionId: record.id, kind: .anomaly, message: "Hook configuration rejected (\(err.description)); no rules are applied in this session", refId: record.id)
            }
            try store.recordClaudeSessionId(sessionId: record.id, claudeSessionId: e.claudeSessionId)
            return record
        }
    }

    func wantsTaskContext(_ s: SessionRecord) -> Bool {
        s.prompt?.context == .task || (s.profileVersion?.profile.rules.contains { $0.context == .task } ?? false)
    }

    /// The session's task: the first user message in Claude Code's transcript (JSONL).
    static func firstUserMessage(transcriptPath: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: (transcriptPath as NSString).expandingTildeInPath) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 2_000_000)) ?? Data()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["type"] as? String == "user", let message = obj["message"] as? [String: Any] else { continue }
            if let text = message["content"] as? String, !text.isEmpty { return text }
            if let blocks = message["content"] as? [[String: Any]] {
                let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
                if !text.isEmpty { return text }
            }
        }
        return nil
    }

    /// The `diorama` CLI shipped next to `dioramad` (Contents/Helpers in the app, .build/… in development).
    static func bundledCLI() -> String? {
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let cli = exe.deletingLastPathComponent().appendingPathComponent("diorama").path
        return FileManager.default.isExecutableFile(atPath: cli) ? cli : nil
    }

    func health() -> HealthInfo {
        HealthInfo(
            version: DioramaVersion.current, pid: getpid(), port: port, startedAt: startedAt, upstream: options.upstream.absoluteString,
            dataDirectory: options.paths.home.path, activeSessions: store.activeSessionCount())
    }

    func keyStatus() -> KeyStatus {
        let k = secrets.get()
        return KeyStatus(configured: k != nil, source: k != nil ? secrets.source : nil, hint: LayeredSecretStore.hint(for: k))
    }

    func doctor() -> DoctorReport {
        var checks: [DoctorCheck] = []
        let settings = store.settings()
        if let claude = ClaudeLocator.find(configured: settings.claudePath, environment: options.environment) {
            checks.append(DoctorCheck(name: "Claude Code", status: .ok, detail: "\(claude) — \(ClaudeLocator.version(at: claude) ?? "version unknown")"))
        } else {
            checks.append(DoctorCheck(name: "Claude Code", status: .failure, detail: "`claude` not found on PATH; install Claude Code or set claudePath in settings"))
        }
        let key = keyStatus()
        let needsKey = options.providerOverride == nil && options.provider == .anthropic
        checks.append(DoctorCheck(
            name: "Rewrite API key", status: key.configured || !needsKey ? .ok : .warning,
            detail: key.configured ? "configured via \(key.source ?? "?") (\(key.hint ?? ""))"
                : needsKey ? "not configured — rules will fail until you run `diorama key set`" : "not needed by the current provider"))
        checks.append(DoctorCheck(name: "Rewrite provider", status: .ok, detail: options.providerOverride?.id ?? options.provider.rawValue))
        checks.append(DoctorCheck(
            name: "Database", status: store.db.quickCheck() ? .ok : .failure,
            detail: "schema v\(store.db.userVersion), \(options.paths.database.path)" + (store.recoveryNote.map { " — \($0)" } ?? "")))
        let bytes = store.blobs.totalBytes()
        checks.append(DoctorCheck(name: "Capture storage", status: bytes > 5_000_000_000 ? .warning : .ok, detail: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + ", retention \(settings.retentionDays) days"))
        // Settings that could fight with Diorama's routing (informational: --settings wins).
        let home = options.environment["HOME"] ?? NSHomeDirectory()
        for path in ["\(home)/.claude/settings.json", "\(home)/.claude/settings.local.json"] {
            guard let data = FileManager.default.contents(atPath: path),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let env = obj["env"] as? [String: Any] ?? [:]
            if env["ANTHROPIC_BASE_URL"] != nil {
                checks.append(DoctorCheck(name: "User settings", status: .warning, detail: "\(path) sets ANTHROPIC_BASE_URL; Diorama overrides it per session via --settings, but other sessions keep using it"))
            }
            if obj["apiKeyHelper"] != nil || env["ANTHROPIC_AUTH_TOKEN"] != nil || env["ANTHROPIC_API_KEY"] != nil {
                checks.append(DoctorCheck(name: "Claude Code credentials", status: .ok, detail: "\(path) configures a credential; Diorama forwards it unchanged"))
            }
        }
        // Ollama is optional: only `ollama:` models need it.
        let ollamaURL = settings.ollamaURL
        var ollamaUp = false
        if let url = URL(string: ollamaURL + "/api/tags") {
            var req = URLRequest(url: url)
            req.timeoutInterval = 1.5
            let sem = DispatchSemaphore(value: 0)
            final class Flag: @unchecked Sendable { var up = false }
            let flag = Flag()
            URLSession.shared.dataTask(with: req) { _, resp, _ in
                flag.up = (resp as? HTTPURLResponse)?.statusCode == 200
                sem.signal()
            }.resume()
            _ = sem.wait(timeout: .now() + 2)
            ollamaUp = flag.up
        }
        checks.append(DoctorCheck(name: "Ollama (optional)", status: .ok, detail: ollamaUp ? "reachable at \(ollamaURL); use models like ollama:llama3.1" : "not running at \(ollamaURL) — only needed for ollama: models"))
        checks.append(DoctorCheck(name: "Gateway", status: .ok, detail: "listening on 127.0.0.1:\(port), upstream \(options.upstream.absoluteString)"))
        checks += configurationChecks(settings: settings)
        return DoctorReport(checks: checks)
    }

    /// Checks of Diorama's own configuration: things that silently stop steering or surprise later.
    func configurationChecks(settings: DioramaSettings) -> [DoctorCheck] {
        var checks: [DoctorCheck] = []
        if settings.steeringPaused {
            checks.append(DoctorCheck(name: "Steering", status: .warning, detail: "paused everywhere: tool results reach Claude unchanged until `diorama resume`"))
        }
        if let cap = settings.dailyBudgetUSD, cap > 0 {
            let spent = store.spend(since: Calendar.current.startOfDay(for: Date()))
            if spent >= cap * 0.8 {
                checks.append(DoctorCheck(name: "Budget", status: .warning, detail: String(format: "$%.4f of the $%.2f daily budget used today", spent, cap)
                    + (spent >= cap ? ": rewrites are paused until tomorrow" : "")))
            }
        }
        let profiles = (try? store.profiles()) ?? []
        let known = Set(profiles.flatMap { [$0.id, $0.name] })
        for (folder, profile) in settings.folderProfiles.sorted(by: { $0.key < $1.key }) {
            if !known.contains(profile) {
                checks.append(DoctorCheck(name: "Folder default", status: .warning, detail: "\(folder) uses '\(profile)', which doesn't exist (any more); `diorama run` there runs without a profile. Fix with `diorama folders set`"))
            } else if !FileManager.default.fileExists(atPath: folder) {
                checks.append(DoctorCheck(name: "Folder default", status: .warning, detail: "\(folder) doesn't exist; remove it with `diorama folders unset`"))
            }
        }
        var failing: [String] = []
        var shadow: [String] = []
        var review: [String] = []
        for p in profiles {
            guard let v = try? store.currentProfileVersion(profileId: p.id) else { continue }
            let results = ProfileTests.run(v.profile)
            let failed = results.filter { !$0.passed }.count
            if failed > 0 { failing.append("“\(p.name)” (\(failed) of \(results.count))") }
            if v.profile.defaults.shadow { shadow.append("“\(p.name)”") }
            if v.profile.defaults.review { review.append("“\(p.name)”") }
        }
        if !failing.isEmpty {
            checks.append(DoctorCheck(name: "Rule tests", status: .warning, detail: "failing in " + failing.joined(separator: ", ") + "; see `diorama profiles check <profile>`"))
        }
        if !shadow.isEmpty {
            checks.append(DoctorCheck(name: "Shadow mode", status: .ok, detail: "on for " + shadow.joined(separator: ", ") + ": rewrites are computed and paid for but never sent"))
        }
        if !review.isEmpty {
            checks.append(DoctorCheck(name: "Review mode", status: .ok, detail: "on for " + review.joined(separator: ", ") + ": Claude waits for you to approve each rewrite"))
        }
        return checks
    }
}

final class SessionFactoryBox: @unchecked Sendable {
    var make: (@Sendable (SessionSpec) throws -> SessionLaunch)?
}

/// Top-level request routing with host/origin and auth checks.
struct Router: HTTPHandler {
    let daemon: DioramaDaemon

    func handle(_ req: HTTPRequest, _ writer: ResponseWriter) async {
        // DNS-rebinding and browser protection: only loopback hosts, never browser origins.
        let host = (req.header("host") ?? "").lowercased()
        let hostName = host.hasPrefix("[") ? String(host.prefix { $0 != "]" }.dropFirst()) : String(host.split(separator: ":").first ?? "")
        guard ["127.0.0.1", "localhost", "::1"].contains(hostName), req.header("origin") == nil else {
            try? await writer.send(403, [("content-type", "application/json"), ("x-should-retry", "false")], Array(#"{"error":"forbidden host or origin"}"#.utf8))
            return
        }
        if req.path.hasPrefix("/s/") {
            let afterPrefix = req.uri.dropFirst(3)
            let token = String(afterPrefix.prefix { $0 != "/" && $0 != "?" })
            let rest = String(afterPrefix.dropFirst(token.count))
            let handler = GatewayHandler(
                store: daemon.store, engine: daemon.engine, upstream: daemon.upstream, upstreamBase: daemon.options.upstream,
                hub: daemon.hub, sessions: daemon.sessions)
            await handler.handle(token: token, rest: rest, req, writer)
            return
        }
        if req.path.hasPrefix("/api/v1/") {
            let auth = req.header("authorization") ?? ""
            guard auth.hasPrefix("Bearer "), Hashing.constantTimeEqual(String(auth.dropFirst(7)), daemon.controlToken) else {
                try? await writer.send(401, [("content-type", "application/json")], Array(#"{"error":"missing or invalid control token"}"#.utf8))
                return
            }
            await ControlAPI(daemon: daemon).handle(req, writer)
            return
        }
        try? await writer.send(404, [("content-type", "application/json")], Array(#"{"error":"not found"}"#.utf8))
    }
}
