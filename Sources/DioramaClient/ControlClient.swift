import DioramaCore
import Darwin
import Foundation

public struct ClientError: Error, CustomStringConvertible, Sendable {
    public let status: Int
    public let message: String
    public var description: String { status > 0 ? "\(message) (HTTP \(status))" : message }
    public init(status: Int = 0, _ message: String) {
        self.status = status
        self.message = message
    }
}

/// Typed client for the daemon's control API (shared by the CLI and the app).
public struct ControlClient: Sendable {
    public let info: DaemonInfo
    let session: URLSession

    public init(info: DaemonInfo) {
        self.info = info
        let cfg = URLSessionConfiguration.ephemeral
        // Hook calls can wait for a rewrite and then a review (review mode).
        cfg.timeoutIntervalForRequest = 300
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
        session = URLSession(configuration: cfg)
    }

    // MARK: Connecting

    /// Reads `daemon.json`, verifies the daemon answers, and optionally starts it.
    public static func connect(paths: DioramaPaths = .default(), autostart: Bool = true, daemonExecutable: String? = nil, timeout: TimeInterval = 15) async throws -> ControlClient {
        if let info = DaemonInfo.read(from: paths.daemonInfo) {
            let c = ControlClient(info: info)
            if (try? await c.health()) != nil { return c }
        }
        guard autostart else { throw ClientError("The Diorama daemon is not running. Start it with `diorama daemon start`.") }
        guard let exe = daemonExecutable ?? DaemonLauncher.locate() else {
            throw ClientError("Could not find the `dioramad` executable. Reinstall Diorama or set DIORAMA_DAEMON.")
        }
        try DaemonLauncher.spawn(executable: exe, paths: paths)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(150))
            if let info = DaemonInfo.read(from: paths.daemonInfo) {
                let c = ControlClient(info: info)
                if (try? await c.health()) != nil { return c }
            }
        }
        throw ClientError("The Diorama daemon did not start within \(Int(timeout))s; see \(paths.logs.appendingPathComponent("dioramad.log").path)")
    }

    // MARK: Transport

    func request<T: Decodable>(_ method: String, _ path: String, query: [String: String] = [:], body: (some Encodable)? = Optional<String>.none, as: T.Type = T.self) async throws -> T {
        // `path` segments are already percent-encoded (urlPathEscaped); appendingPathComponent would encode them twice.
        var comps = URLComponents(url: info.controlBaseURL, resolvingAgainstBaseURL: false)!
        comps.percentEncodedPath = comps.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
            ? "/" + path : comps.percentEncodedPath + (comps.percentEncodedPath.hasSuffix("/") ? "" : "/") + path
        if !query.isEmpty { comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue("Bearer \(info.controlToken)", forHTTPHeaderField: "authorization")
        if let body {
            req.httpBody = try DioramaCoding.encoder.encode(body)
            req.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let msg = (try? DioramaCoding.decoder.decode(APIErrorBody.self, from: data))?.error ?? String(decoding: data, as: UTF8.self)
            throw ClientError(status: status, msg)
        }
        do {
            return try DioramaCoding.decoder.decode(T.self, from: data)
        } catch {
            throw ClientError(status: status, "could not decode \(T.self) from \(path): \(error)")
        }
    }

    // MARK: Endpoints

    public func health() async throws -> HealthInfo { try await request("GET", "health") }
    public func doctor() async throws -> DoctorReport { try await request("GET", "doctor") }
    public func settings() async throws -> DioramaSettings { try await request("GET", "settings") }
    public func saveSettings(_ s: DioramaSettings) async throws -> DioramaSettings { try await request("PUT", "settings", body: s) }
    public func keyStatus() async throws -> KeyStatus { try await request("GET", "key") }
    public func setKey(_ key: String) async throws -> KeyStatus { try await request("PUT", "key", body: SetKeyRequest(key: key)) }
    public func deleteKey() async throws -> KeyStatus { try await request("DELETE", "key") }
    public func shutdown() async throws { let _: [String: String] = try await request("POST", "shutdown") }
    public func applyRetention() async throws -> MaintenanceResult { try await request("POST", "maintenance/retention") }

    public func templates() async throws -> [Profile] { try await request("GET", "templates") }
    public func hook(_ event: HookEvent) async throws -> HookReply { try await request("POST", "hook", body: event) }
    public func playground(_ r: PlaygroundRequest) async throws -> PlaygroundResult { try await request("POST", "playground", body: r) }
    public func whatIf(_ r: WhatIfRequest) async throws -> WhatIfResult { try await request("POST", "whatif", body: r) }
    public func spend() async throws -> SpendSummary { try await request("GET", "spend") }
    /// Spending per day for the last `days` days (1–366).
    public func spendHistory(days: Int = 30) async throws -> SpendHistory { try await request("GET", "spend/history", query: ["days": String(days)]) }
    public func search(_ query: String, rewrittenOnly: Bool = false, sessionId: String? = nil, limit: Int = 50) async throws -> [SearchHit] {
        var q = ["q": query, "limit": String(limit)]
        if rewrittenOnly { q["rewritten"] = "1" }
        if let sessionId { q["session"] = sessionId }
        return try await request("GET", "search", query: q)
    }
    public func recentToolResults(limit: Int = 50) async throws -> [RecentToolResult] { try await request("GET", "decisions", query: ["limit": String(limit)]) }
    public func profiles() async throws -> [ProfileSummary] { try await request("GET", "profiles") }
    public func profile(_ id: String) async throws -> ProfileDetail { try await request("GET", "profiles/\(id.urlPathEscaped)") }
    /// Per-rule usage over the last `days` days (0 = all time).
    public func ruleStats(_ profile: String, days: Int = 30, includeTrials: Bool = false) async throws -> ProfileRuleStats {
        try await request("GET", "profiles/\(profile.urlPathEscaped)/stats", query: ["days": String(days), "trials": includeTrials ? "1" : "0"])
    }
    public func createProfile(_ p: Profile) async throws -> ProfileVersionInfo { try await request("POST", "profiles", body: p) }
    public func updateProfile(_ id: String, _ p: Profile) async throws -> ProfileDetail { try await request("PUT", "profiles/\(id.urlPathEscaped)", body: p) }
    public func archiveProfile(_ id: String) async throws { let _: [String: String] = try await request("DELETE", "profiles/\(id.urlPathEscaped)") }

    public func sessions(kind: SessionKind? = nil, tag: String? = nil, limit: Int = 200) async throws -> [SessionInfo] {
        var q = ["limit": String(limit)]
        if let kind { q["kind"] = kind.rawValue }
        if let tag { q["tag"] = tag }
        return try await request("GET", "sessions", query: q)
    }
    /// Renames a session or sets its notes or tags (nil fields stay as they are).
    public func annotate(_ id: String, _ a: SessionAnnotations) async throws -> SessionInfo { try await request("PUT", "sessions/\(id)/annotations", body: a) }
    /// Tags in use, most used first.
    public func sessionTags() async throws -> [String] { try await request("GET", "session-tags") }
    public func createSession(_ spec: SessionSpec) async throws -> SessionLaunch { try await request("POST", "sessions", body: spec) }
    public func session(_ id: String) async throws -> SessionInfo { try await request("GET", "sessions/\(id)") }
    public func endSession(_ id: String) async throws -> SessionInfo { try await request("POST", "sessions/\(id)/end") }
    /// Pauses or resumes steering for one session.
    public func setPaused(_ id: String, _ paused: Bool) async throws -> SessionInfo { try await request("POST", "sessions/\(id)/\(paused ? "pause" : "resume")") }
    /// Pauses or resumes steering everywhere.
    /// Decided tool results as CSV or JSON Lines. `days` 0 = all time; `profile` by name or id.
    public func exportDecisions(format: DataExport.Format = .csv, days: Int = 0, sessionId: String? = nil, profile: String? = nil,
                                includeTrials: Bool = true, rewrittenOnly: Bool = false, includeTexts: Bool = false) async throws -> DecisionExport {
        var q = ["format": format.rawValue, "days": String(days), "trials": includeTrials ? "1" : "0"]
        if let sessionId { q["session"] = sessionId }
        if let profile { q["profile"] = profile }
        if rewrittenOnly { q["rewritten"] = "1" }
        if includeTexts { q["texts"] = "1" }
        return try await request("GET", "export/decisions", query: q)
    }

    /// Rewrites waiting for approval (review mode).
    public func pendingReviews() async throws -> [PendingReview] { try await request("GET", "reviews") }
    public func resolveReview(_ id: String, approve: Bool) async throws {
        let _: [String: String] = try await request("POST", "reviews/\(id.urlPathEscaped)/\(approve ? "approve" : "reject")")
    }
    public func setSteeringPaused(_ paused: Bool) async throws -> DioramaSettings { try await request("POST", "steering/\(paused ? "pause" : "resume")") }
    public func timeline(_ id: String) async throws -> Timeline { try await request("GET", "sessions/\(id)/timeline") }
    /// A session's audit trail as a document: "md" or "html".
    public func sessionReport(_ sessionId: String, format: String = "md") async throws -> String {
        let r: [String: String] = try await request("GET", "sessions/\(sessionId)/report", query: ["format": format])
        return r["content"] ?? ""
    }
    public func experimentDraft(sessionId: String, trials: Int = 5) async throws -> ExperimentDraft {
        try await request("GET", "sessions/\(sessionId)/experiment-draft", query: ["trials": String(trials)])
    }
    public func decision(_ toolUseId: String) async throws -> DecisionDetail { try await request("GET", "decisions/\(toolUseId.urlPathEscaped)") }
    public func exchange(_ id: Int64) async throws -> ExchangeSummary { try await request("GET", "exchanges/\(id)") }
    public func exchangeRaw(_ id: Int64) async throws -> ExchangeRawPayload { try await request("GET", "exchanges/\(id)/raw") }
    public func events(session: String? = nil, after: Int64 = 0) async throws -> [SessionEvent] {
        var q = ["after": String(after)]
        if let session { q["session"] = session }
        return try await request("GET", "events", query: q)
    }

    public func experiments() async throws -> [ExperimentInfo] { try await request("GET", "experiments") }
    public func createExperiment(_ d: ExperimentDefinition) async throws -> ExperimentInfo { try await request("POST", "experiments", body: d) }
    public func experiment(_ id: String) async throws -> ExperimentInfo { try await request("GET", "experiments/\(id)") }
    public func prepareRun(experimentId: String) async throws -> RunSummary { try await request("POST", "experiments/\(experimentId)/runs") }
    public func run(_ id: String) async throws -> RunSummary { try await request("GET", "runs/\(id)") }
    public func startRun(_ id: String, confirmationToken: String) async throws -> RunSummary {
        try await request("POST", "runs/\(id)/start", body: StartRunRequest(confirmationToken: confirmationToken))
    }
    public func cancelRun(_ id: String) async throws -> RunSummary { try await request("POST", "runs/\(id)/cancel") }
    public func comparison(_ runId: String) async throws -> RunComparison { try await request("GET", "runs/\(runId)/comparison") }
    /// Several runs of one experiment pooled (all completed runs when `runIds` is nil).
    public func pooledComparison(experimentId: String, runIds: [String]? = nil) async throws -> RunComparison {
        try await request("GET", "experiments/\(experimentId)/comparison", query: runIds.map { ["runs": $0.joined(separator: ",")] } ?? [:])
    }
    public func pooledReport(experimentId: String, runIds: [String]? = nil, format: String) async throws -> String {
        var q = ["format": format]
        if let runIds { q["runs"] = runIds.joined(separator: ",") }
        let r: [String: String] = try await request("GET", "experiments/\(experimentId)/report", query: q)
        return r["content"] ?? ""
    }
    public func report(_ runId: String, format: String) async throws -> String {
        let r: [String: String] = try await request("GET", "runs/\(runId)/report", query: ["format": format])
        return r["content"] ?? ""
    }
    public func trialTranscript(_ id: String) async throws -> String {
        let r: [String: String] = try await request("GET", "trials/\(id)/transcript")
        return r["content"] ?? ""
    }

    /// Live events (server-sent events). The stream ends when the daemon goes away.
    public func eventStream(session filter: String? = nil) -> AsyncThrowingStream<SessionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var comps = URLComponents(url: info.controlBaseURL.appendingPathComponent("events/stream"), resolvingAgainstBaseURL: false)!
                if let filter { comps.queryItems = [URLQueryItem(name: "session", value: filter)] }
                var req = URLRequest(url: comps.url!)
                req.setValue("Bearer \(info.controlToken)", forHTTPHeaderField: "authorization")
                req.timeoutInterval = 3600
                do {
                    let (bytes, response) = try await session.bytes(for: req)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ClientError("event stream rejected") }
                    var data = ""
                    for try await line in bytes.lines {
                        if line.hasPrefix("data: ") {
                            data += String(line.dropFirst(6))
                            if let ev = try? DioramaCoding.decoder.decode(SessionEvent.self, from: Data(data.utf8)) {
                                continuation.yield(ev)
                                data = ""
                            }
                        } else if line.isEmpty {
                            data = ""
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension String {
    var urlPathEscaped: String { addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? self }
}

/// Locates and starts `dioramad` as a detached background process.
public enum DaemonLauncher {
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let fm = FileManager.default
        if let p = environment["DIORAMA_DAEMON"], fm.isExecutableFile(atPath: p) { return p }
        var candidates: [String] = []
        // Inside Diorama.app the daemon and CLI live in Contents/Helpers.
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/dioramad").path)
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            candidates.append(exe.deletingLastPathComponent().appendingPathComponent("dioramad").path)
        }
        let argv0 = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        candidates.append(argv0.deletingLastPathComponent().appendingPathComponent("dioramad").path)
        candidates += ["/Applications/Diorama.app/Contents/Helpers/dioramad", "\(NSHomeDirectory())/Applications/Diorama.app/Contents/Helpers/dioramad"]
        for d in (environment["PATH"] ?? "").split(separator: ":") { candidates.append("\(d)/dioramad") }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    /// Spawns the daemon in its own session (immune to the terminal's Ctrl-C and hangup), with
    /// output appended to `logs/dioramad.log`.
    public static func spawn(executable: String, paths: DioramaPaths, extraArguments: [String] = []) throws {
        try paths.ensureDirectories()
        let log = paths.logs.appendingPathComponent("dioramad.log").path
        var attr = posix_spawnattr_t(bitPattern: 0)
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        var actions = posix_spawn_file_actions_t(bitPattern: 0)
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, log, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        let args = [executable, "--home", paths.home.path] + extraArguments
        var env = ProcessInfo.processInfo.environment
        env["DIORAMA_HOME"] = paths.home.path
        let cArgs = args.map { strdup($0) } + [nil]
        let cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            cArgs.forEach { free($0) }
            cEnv.forEach { free($0) }
        }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &actions, &attr, cArgs, cEnv)
        guard rc == 0 else { throw ClientError("could not start dioramad (\(String(cString: strerror(rc))))") }
    }
}
