import DioramaCore
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
        background.append(Task { [store] in
            while !Task.isCancelled {
                _ = try? store.applyRetention(days: store.settings().retentionDays)
                try? await Task.sleep(for: .seconds(24 * 3600))
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
        let json = String(decoding: try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        return SessionLaunch(session: try store.info(record), token: token, baseURL: base, environment: env, claudeArguments: ["--settings", json])
    }

    // MARK: Hook mode

    /// Handles one Claude Code hook event (hook mode: Claude desktop, IDEs). Sessions are keyed
    /// by Claude's session id; their configuration is fixed when the first event arrives.
    func handleHook(_ e: HookEvent) async throws -> HookReply {
        guard !e.claudeSessionId.isEmpty else { throw RunnerError("hook event without a session id") }
        guard let session = try hookSession(e) else { return HookReply() }
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
        return DoctorReport(checks: checks)
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
