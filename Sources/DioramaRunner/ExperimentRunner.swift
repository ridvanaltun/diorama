import DioramaCore
import DioramaStore
import Foundation

public struct RunnerError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ d: String) { description = d }
}

/// Orchestrates A/B experiment runs: isolated project clones, headless `claude -p` trials
/// routed through the gateway, facts/heuristics extraction, comparisons and reports.
public final class ExperimentRunner: @unchecked Sendable {
    public typealias SessionFactory = @Sendable (SessionSpec) throws -> SessionLaunch

    let store: Store
    let paths: DioramaPaths
    let makeSession: SessionFactory
    let claudePath: @Sendable () -> String?
    let baseEnvironment: [String: String]
    private let lock = NSLock()
    private var runTasks: [String: Task<Void, Never>] = [:]
    private var processes: [String: TrialProcess] = [:]

    public init(store: Store, paths: DioramaPaths, environment: [String: String] = ProcessInfo.processInfo.environment,
                claudePath: @escaping @Sendable () -> String?, makeSession: @escaping SessionFactory) {
        self.store = store
        self.paths = paths
        self.makeSession = makeSession
        self.claudePath = claudePath
        baseEnvironment = environment
    }

    // MARK: Definitions

    public func create(_ definition: ExperimentDefinition) throws -> ExperimentInfo {
        var def = definition
        def.projectPath = (def.projectPath as NSString).expandingTildeInPath
        let problems = def.validate()
        guard problems.isEmpty else { throw RunnerError(problems.joined(separator: "; ")) }
        for v in def.variants {
            if let p = v.profile, try store.resolveProfile(p) == nil { throw RunnerError("variant '\(v.key)': unknown profile '\(p)'") }
        }
        return try store.createExperiment(def)
    }

    // MARK: Estimates

    static let baselines: [String: (Double, Double)] = [
        "claude-opus-5-5": (0.6, 2.5), "claude-sonnet-5-5": (0.3, 1.2), "claude-haiku-5-5": (0.02, 0.15), "claude-fable-5-1": (1.5, 6.0),
    ]

    /// Creates a pending run with a cost estimate. The run starts only when `start` is called
    /// with the estimate's confirmation token (FR-31).
    public func prepareRun(experimentId: String) throws -> RunSummary {
        guard let exp = try store.experiment(id: experimentId) else { throw RunnerError("unknown experiment \(experimentId)") }
        let def = exp.definition
        let trials = def.trialsPerVariant * def.variants.count
        let model = def.claude.model
        var notes: [String] = []
        let low: Double, high: Double, basis: String
        if let h = try store.historicalTrialCost(model: model), h.n >= 2 {
            low = h.mean * 0.7
            high = h.mean * 1.5
            basis = "average of \(h.n) previous trial(s) on \(model ?? "the default model") (±)"
        } else {
            let key = model ?? "claude-opus-5-5"
            let b = Self.baselines[key] ?? (0.5, 2.5)
            (low, high) = b
            basis = "baseline for \(key) (no history yet)"
            notes.append("Baselines include Claude Code's ~35K-token system prompt per trial; long or tool-heavy tasks cost more.")
        }
        // Rewrite agent cost: rough per-rewrite figure by model, times expected rewrites.
        var rewriteLow = 0.0, rewriteHigh = 0.0
        for v in def.variants where !v.isControl {
            var rewriteModel = v.prompt?.model ?? ProfileDefaults.defaultModel
            if let p = v.profile, let pv = try store.resolveProfile(p) { rewriteModel = pv.profile.rules.compactMap(\.model).last ?? pv.profile.defaults.model }
            let per: (Double, Double) = rewriteModel.contains("haiku") ? (0.0005, 0.01) : rewriteModel.contains("sonnet") ? (0.01, 0.12) : (0.02, 0.25)
            let count = def.treatment == .frozen ? 3.0 : 3.0 * Double(def.trialsPerVariant)
            rewriteLow += per.0 * count * 0.5
            rewriteHigh += per.1 * count * 2
        }
        notes.append("Claude Code usage is billed to the account Claude Code is signed in with; on subscription plans the figures are notional and count toward plan limits.")
        notes.append("Rewrite-agent calls use your Anthropic API key.")
        if def.treatment == .frozen { notes.append("Frozen treatment: identical tool results reuse one rewrite across trials.") }
        let estimate = CostEstimate(
            trials: trials, perTrialLowUSD: low, perTrialHighUSD: high, rewriteLowUSD: rewriteLow, rewriteHighUSD: rewriteHigh,
            basis: basis, notes: notes, confirmationToken: Hashing.randomToken(bytes: 8))
        let seed = def.seed ?? UInt64.random(in: 1...UInt64(Int64.max))
        let order = Self.blockedOrder(variants: def.variants.map(\.key), trialsPerVariant: def.trialsPerVariant, seed: seed)
        return try store.createRun(experimentId: experimentId, seed: seed, estimate: estimate, trials: order.enumerated().map { (variant: $1.0, index: $1.1, order: $0) })
    }

    /// Blocked randomization: every round contains each variant once, in a seeded random
    /// order, so time-varying conditions (API load, caches) can't line up with one variant.
    public static func blockedOrder(variants: [String], trialsPerVariant: Int, seed: UInt64) -> [(String, Int)] {
        var g = SeededGenerator(seed: seed)
        var order: [(String, Int)] = []
        for round in 0..<trialsPerVariant {
            for key in variants.shuffled(using: &g) { order.append((key, round)) }
        }
        return order
    }

    // MARK: Execution

    public func start(runId: String, confirmationToken: String) throws -> RunSummary {
        guard let run = try store.run(id: runId), let exp = try store.experiment(id: run.experimentId) else { throw RunnerError("unknown run \(runId)") }
        guard run.status == .pending else { throw RunnerError("run is \(run.status.rawValue), not pending") }
        guard let expected = try store.runConfirmationToken(id: runId), Hashing.constantTimeEqual(expected, confirmationToken) else {
            throw RunnerError("confirmation token does not match this run's cost estimate")
        }
        guard let claude = claudePath() else { throw RunnerError("could not find the `claude` executable; set its path in settings") }
        try store.setRunStatus(id: runId, .running)
        store.addEvent(sessionId: nil, kind: .runStarted, message: "Run started for '\(exp.name)' (\(run.trialsTotal) trials)", refId: runId)
        let task = Task { [self] in
            await self.execute(run: run, experiment: exp, claude: claude)
        }
        lock.withLock { runTasks[runId] = task }
        return try store.run(id: runId)!
    }

    public func cancel(runId: String) throws {
        let task = lock.withLock { runTasks[runId] }
        guard let task else {
            if let r = try store.run(id: runId), r.status == .pending { try store.setRunStatus(id: runId, .cancelled) }
            return
        }
        task.cancel()
        let procs = lock.withLock { Array(processes.values) }
        for p in procs { p.terminate() }
    }

    public var activeRunIds: [String] { lock.withLock { Array(runTasks.keys) } }

    public func waitForRun(_ runId: String) async {
        let t = lock.withLock { runTasks[runId] }
        await t?.value
    }

    func execute(run: RunSummary, experiment: ExperimentInfo, claude: String) async {
        let def = experiment.definition
        let source = URL(fileURLWithPath: def.projectPath)
        let sourceHashes = ProjectCloner.fileHashes(source)
        let snapshot = ProjectCloner.snapshotIdentity(source)
        let claudeVersion = ClaudeLocator.version(at: claude)
        let trials = (try? store.trials(runId: run.id)) ?? []
        let limit = max(1, def.concurrency)
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            for t in trials where t.status == .pending {
                if Task.isCancelled { break }
                if running >= limit {
                    await group.next()
                    running -= 1
                }
                if Task.isCancelled { break }
                running += 1
                group.addTask {
                    await self.runTrial(t, run: run, experiment: experiment, claude: claude, claudeVersion: claudeVersion, source: source, sourceHashes: sourceHashes, snapshot: snapshot)
                }
            }
            await group.waitForAll()
        }
        let cancelled = Task.isCancelled
        for t in (try? store.trials(runId: run.id)) ?? [] where t.status == .pending || t.status == .running {
            try? store.trialFinished(id: t.id, status: .cancelled, facts: nil, signals: nil, error: "run cancelled", transcriptBlob: nil)
        }
        try? store.setRunStatus(id: run.id, cancelled ? .cancelled : .completed)
        store.addEvent(sessionId: nil, kind: .runFinished, message: "Run \(cancelled ? "cancelled" : "completed") for '\(experiment.name)'", refId: run.id)
        _ = lock.withLock { runTasks.removeValue(forKey: run.id) }
    }

    func trialEnvironment(launch: SessionLaunch) -> [String: String] {
        var env = baseEnvironment.filter { k, _ in
            !(k.hasPrefix("CLAUDE") && k != "CLAUDE_CONFIG_DIR") && k != "ANTHROPIC_BASE_URL" && !k.hasPrefix("DIORAMA_")
        }
        for (k, v) in launch.environment { env[k] = v }
        env["DISABLE_AUTOUPDATER"] = "1"
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        if env["USER"] == nil { env["USER"] = NSUserName() }
        if env["LOGNAME"] == nil { env["LOGNAME"] = NSUserName() }
        return env
    }

    static func arguments(definition def: ExperimentDefinition, launch: SessionLaunch) -> [String] {
        var args = ["-p", "--output-format", "stream-json", "--verbose", "--no-session-persistence"]
        let o = def.claude
        if let m = o.model { args += ["--model", m] }
        if let pm = o.permissionMode { args += ["--permission-mode", pm] }
        if !o.allowedTools.isEmpty { args += ["--allowedTools", o.allowedTools.joined(separator: ",")] }
        if !o.disallowedTools.isEmpty { args += ["--disallowedTools", o.disallowedTools.joined(separator: ",")] }
        if let t = o.maxTurns { args += ["--max-turns", String(t)] }
        if let b = o.maxBudgetUSD { args += ["--max-budget-usd", String(b)] }
        if o.isolateConfiguration { args += ["--setting-sources", "project,local", "--strict-mcp-config"] }
        args += launch.claudeArguments
        args += o.extraArguments
        return args
    }

    func runTrial(_ trial: TrialInfo, run: RunSummary, experiment: ExperimentInfo, claude: String, claudeVersion: String?, source: URL, sourceHashes: [String: String], snapshot: String) async {
        let def = experiment.definition
        guard let variant = def.variants.first(where: { $0.key == trial.variantKey }) else { return }
        let trialDir = paths.runs.appendingPathComponent(run.id).appendingPathComponent(trial.id)
        let workdir = trialDir.appendingPathComponent("project")
        func fail(_ msg: String, status: TrialStatus = .failed) {
            try? store.trialFinished(id: trial.id, status: status, facts: nil, signals: nil, error: msg, transcriptBlob: nil)
            store.addEvent(sessionId: nil, kind: .trialFinished, message: "Trial \(trial.order + 1) (\(variant.key)) \(status.rawValue): \(msg)", refId: trial.id)
        }
        do {
            try ProjectCloner.clone(source, to: workdir)
        } catch {
            fail("could not copy the project: \(error.localizedDescription)")
            return
        }
        defer { try? FileManager.default.removeItem(at: workdir) }
        let spec = SessionSpec(
            name: "\(experiment.name) · \(variant.key) #\(trial.index + 1)", cwd: workdir.path, profile: variant.profile, prompt: variant.prompt,
            lockdown: variant.lockdown, kind: .trial, trialId: trial.id, onFailure: .invalidateTrial,
            treatmentScope: variant.isControl ? nil : (def.treatment == .frozen ? "\(run.id):\(variant.key)" : nil))
        let launch: SessionLaunch
        do { launch = try makeSession(spec) } catch {
            fail("could not create the trial session: \(error)")
            return
        }
        let args = Self.arguments(definition: def, launch: launch)
        let env = trialEnvironment(launch: launch)
        let manifestEnv = Dictionary(uniqueKeysWithValues: launch.environment.map { k, v in (k, k.contains("BASE_URL") ? "http://127.0.0.1:<port>/s/<session-token>" : v) })
            .merging(["DISABLE_AUTOUPDATER": "1"]) { a, _ in a }
        let manifest = TrialManifest(
            dioramaVersion: DioramaVersion.current, rewritePromptVersion: DioramaVersion.rewritePromptVersion, claudeVersion: claudeVersion,
            claudePath: claude, arguments: args.map { $0.contains("/s/") ? "<settings with session token>" : $0 }, environment: manifestEnv,
            model: def.claude.model, variantKey: variant.key, profileVersionId: launch.session.profileVersionId,
            promptHash: variant.prompt.map { Hashing.sha256Hex($0.text).prefix(16).description }, treatment: def.treatment,
            experimentDefinitionHash: experiment.definitionHash, projectSnapshot: snapshot,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString, seed: run.seed, order: trial.order)
        try? store.trialStarted(id: trial.id, sessionId: launch.session.id, workdir: workdir.path, manifest: manifest)
        store.addEvent(sessionId: launch.session.id, kind: .trialStarted, message: "Trial \(trial.order + 1) (\(variant.key)) started", refId: trial.id)

        let stdoutURL = trialDir.appendingPathComponent("stdout.jsonl")
        let stderrURL = trialDir.appendingPathComponent("stderr.txt")
        let taskURL = trialDir.appendingPathComponent("task.txt")
        let started = Date()
        let proc: TrialProcess
        do {
            try Data(def.task.utf8).write(to: taskURL)
            proc = try TrialProcess(path: claude, args: args, cwd: workdir.path, environment: env, stdout: stdoutURL, stderr: stderrURL)
            proc.process.standardInput = try FileHandle(forReadingFrom: taskURL)
            try proc.start()
        } catch {
            try? store.endSession(id: launch.session.id)
            fail("could not start claude: \(error.localizedDescription)")
            return
        }
        lock.withLock { processes[trial.id] = proc }
        let (exitCode, timedOut) = await proc.wait(timeout: def.claude.timeoutSeconds)
        _ = lock.withLock { processes.removeValue(forKey: trial.id) }
        try? store.endSession(id: launch.session.id)

        let stdout = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
        let stderr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        let transcriptBlob = try? store.blobs.put(stdout)
        let transcript = StreamTranscript.parse(stdout)
        let decisions = (try? store.decisions(sessionId: launch.session.id)) ?? []
        let rewriteCost = (try? store.stats(sessionId: launch.session.id).rewriteCostUSD) ?? 0
        let afterHashes = ProjectCloner.fileHashes(workdir)
        let changed = Set(sourceHashes.keys).union(afterHashes.keys).filter { sourceHashes[$0] != afterHashes[$0] }.sorted()
        let facts = TrialFacts(
            finalOutput: transcript.finalOutput, isError: transcript.isError, exitCode: exitCode,
            durationMs: transcript.durationMs ?? Date().timeIntervalSince(started) * 1000, numTurns: transcript.numTurns,
            toolCalls: transcript.toolCalls, rewritesApplied: decisions.filter { $0.outcome == .rewritten }.count,
            rewriteFailures: decisions.filter { $0.outcome == .failed }.count, usage: transcript.usage, claudeCostUSD: transcript.costUSD,
            rewriteCostUSD: rewriteCost, filesChanged: Array(changed.prefix(200)))
        let signals = Heuristics.signals(transcript: transcript, decisions: decisions, store: store)
        let flags = (try? store.session(id: launch.session.id))?.flags ?? []
        let status: TrialStatus
        var error: String?
        if proc.wasTerminated, !timedOut {
            status = .cancelled
            error = "cancelled"
        } else if timedOut {
            status = .failed
            error = "timed out after \(Int(def.claude.timeoutSeconds))s"
        } else if !transcript.sawResult {
            status = .failed
            let tail = stderr.split(whereSeparator: \.isNewline).suffix(3).joined(separator: " | ")
            error = "claude exited \(exitCode) without a result" + (tail.isEmpty ? "" : ": \(tail)")
        } else if flags.contains("trial-invalid") {
            status = .invalid
            error = "a rewrite failed during this trial, so it did not receive the intended treatment"
        } else {
            status = .succeeded
        }
        try? store.trialFinished(id: trial.id, status: status, facts: facts, signals: signals, error: error, transcriptBlob: transcriptBlob)
        store.addEvent(sessionId: launch.session.id, kind: .trialFinished, message: "Trial \(trial.order + 1) (\(variant.key)) \(status.rawValue)", refId: trial.id)
    }

    // MARK: Results

    public func comparison(runId: String) throws -> RunComparison {
        guard let run = try store.run(id: runId), let exp = try store.experiment(id: run.experimentId) else { throw RunnerError("unknown run \(runId)") }
        return Comparison.compare(run: run, definition: exp.definition, trials: try store.trials(runId: runId))
    }

    public func report(runId: String, format: String) throws -> String {
        guard let run = try store.run(id: runId), let exp = try store.experiment(id: run.experimentId) else { throw RunnerError("unknown run \(runId)") }
        let c = try comparison(runId: runId)
        switch format {
        case "md", "markdown": return Report.markdown(experiment: exp, comparison: c)
        case "json":
            struct Bundle: Encodable {
                let format = "diorama-experiment-bundle/1"
                let experiment: ExperimentInfo
                let comparison: RunComparison
            }
            return String(decoding: try DioramaCoding.prettyEncoder.encode(Bundle(experiment: exp, comparison: c)), as: UTF8.self)
        default: throw RunnerError("unknown report format '\(format)' (use md or json)")
        }
    }
}
