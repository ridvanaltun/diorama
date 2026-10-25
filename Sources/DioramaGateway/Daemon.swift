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
    private var stopped = false

    public init(options: Options) throws {
        self.options = options
        try options.paths.ensureDirectories()
        store = try Store(paths: options.paths)
        sessions = SessionCache(store: store)
        let secrets = options.secrets ?? LayeredSecretStore(override: EnvironmentSecretStore(environment: options.environment), primary: KeychainSecretStore())
        self.secrets = secrets
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
        engine = DecisionEngine(store: store) { provider }
        server = HTTPServer(maxBodyBytes: options.maxBodyBytes)
        let factory = SessionFactoryBox()
        runner = ExperimentRunner(
            store: store, paths: options.paths, environment: options.environment,
            claudePath: { [store] in ClaudeLocator.find(configured: store.settings().claudePath, environment: options.environment) },
            makeSession: { spec in
                guard let make = factory.make else { throw RunnerError("daemon is shutting down") }
                return try make(spec)
            })
        factory.make = { [unowned self] spec in try self.createSession(spec) }
        store.onEvent = { [hub] ev in hub.publish(ev) }
    }

    // MARK: Lifecycle

    /// Acquires the single-instance lock, binds the port and writes `daemon.json`.
    public func start() async throws -> Int {
        if options.writeDaemonInfo {
            lockFD = open(options.paths.daemonLock.path, O_CREAT | O_RDWR, 0o600)
            guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
                throw RunnerError("another Diorama daemon is already running for \(options.paths.home.path)")
            }
        }
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

    public func stop() async {
        let first = stopLock.withLock { () -> Bool in
            if stopped { return false }
            stopped = true
            return true
        }
        guard first else { return }
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
        let env = ["ANTHROPIC_BASE_URL": base, "CLAUDE_CODE_GATEWAY_HINT_HEADERS": "1"]
        // Passing the same env through --settings makes it win over an `env` block in the user's
        // own settings files (settings beat shell exports), without changing any file on disk.
        var settings: [String: Any] = ["env": env]
        let deny = spec.lockdown.disallowedTools
        if !deny.isEmpty { settings["permissions"] = ["deny": deny] }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        return SessionLaunch(session: try store.info(record), token: token, baseURL: base, environment: env, claudeArguments: ["--settings", json])
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
