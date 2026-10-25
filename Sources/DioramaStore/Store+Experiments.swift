import DioramaCore
import Foundation

extension Store {
    // MARK: Experiments

    public func createExperiment(_ def: ExperimentDefinition) throws -> ExperimentInfo {
        let body = json(def)
        let hash = String(Hashing.sha256Hex(body).prefix(24))
        let id = Hashing.newId(prefix: "exp")
        let now = Date()
        try db.run(
            "INSERT INTO experiments(id, name, definition, definition_hash, created_at) VALUES(?, ?, ?, ?, ?)",
            [.text(id), .text(def.name), .text(body), .text(hash), .date(now)])
        return ExperimentInfo(id: id, name: def.name, definition: def, definitionHash: hash, createdAt: now, runs: [])
    }

    public func experiment(id: String) throws -> ExperimentInfo? {
        guard let r = try db.query("SELECT * FROM experiments WHERE id = ?", [.text(id)]).first,
              let def = decode(ExperimentDefinition.self, r.string("definition"))
        else { return nil }
        return ExperimentInfo(
            id: id, name: r.string("name") ?? def.name, definition: def, definitionHash: r.string("definition_hash") ?? "",
            createdAt: r.date("created_at") ?? Date(), runs: try runs(experimentId: id))
    }

    public func experiments() throws -> [ExperimentInfo] {
        try db.query("SELECT id FROM experiments ORDER BY created_at DESC").compactMap { try $0.string("id").flatMap(experiment(id:)) }
    }

    // MARK: Runs

    func runSummary(_ r: Row) throws -> RunSummary {
        let id = r.string("id") ?? ""
        let done = try db.query(
            "SELECT COUNT(*) AS n FROM trials WHERE run_id = ? AND status IN ('succeeded','failed','invalid','cancelled')", [.text(id)]).first?.int("n") ?? 0
        return RunSummary(
            id: id, experimentId: r.string("experiment_id") ?? "", status: RunStatus(rawValue: r.string("status") ?? "") ?? .failed,
            createdAt: r.date("created_at") ?? Date(), startedAt: r.date("started_at"), finishedAt: r.date("finished_at"),
            seed: UInt64(bitPattern: r.int("seed") ?? 0), trialsTotal: Int(r.int("trials_total") ?? 0), trialsDone: Int(done),
            estimate: decode(CostEstimate.self, r.string("estimate")))
    }

    public func createRun(experimentId: String, seed: UInt64, estimate: CostEstimate, trials: [(variant: String, index: Int, order: Int)]) throws -> RunSummary {
        let id = Hashing.newId(prefix: "run")
        let now = Date()
        try db.transaction {
            try db.run(
                "INSERT INTO runs(id, experiment_id, status, created_at, seed, estimate, confirmation_token, trials_total) VALUES(?, ?, 'pending', ?, ?, ?, ?, ?)",
                [.text(id), .text(experimentId), .date(now), .int(Int64(bitPattern: seed)), .text(json(estimate)), .text(estimate.confirmationToken), .int(Int64(trials.count))])
            for t in trials {
                try db.run(
                    "INSERT INTO trials(id, run_id, variant_key, idx, ord, status) VALUES(?, ?, ?, ?, ?, 'pending')",
                    [.text(Hashing.newId(prefix: "tri")), .text(id), .text(t.variant), .int(Int64(t.index)), .int(Int64(t.order))])
            }
        }
        return try run(id: id)!
    }

    public func run(id: String) throws -> RunSummary? {
        try db.query("SELECT * FROM runs WHERE id = ?", [.text(id)]).first.map(runSummary)
    }

    public func runs(experimentId: String) throws -> [RunSummary] {
        try db.query("SELECT * FROM runs WHERE experiment_id = ? ORDER BY created_at DESC", [.text(experimentId)]).map(runSummary)
    }

    public func runConfirmationToken(id: String) throws -> String? {
        try db.query("SELECT confirmation_token FROM runs WHERE id = ?", [.text(id)]).first?.string("confirmation_token")
    }

    public func setRunStatus(id: String, _ status: RunStatus) throws {
        switch status {
        case .running:
            try db.run("UPDATE runs SET status = ?, started_at = ? WHERE id = ?", [.text(status.rawValue), .date(Date()), .text(id)])
        case .completed, .cancelled, .failed:
            try db.run("UPDATE runs SET status = ?, finished_at = ? WHERE id = ?", [.text(status.rawValue), .date(Date()), .text(id)])
        case .pending:
            try db.run("UPDATE runs SET status = ? WHERE id = ?", [.text(status.rawValue), .text(id)])
        }
    }

    /// Runs left `running` by a previous daemon process can't be resumed; mark them failed.
    public func recoverInterruptedRuns() throws -> Int {
        try db.run("UPDATE trials SET status = 'cancelled', error = 'interrupted: the Diorama daemon stopped during the trial', finished_at = ? WHERE status = 'running'", [.date(Date())])
        try db.run("UPDATE runs SET status = 'failed', finished_at = ? WHERE status = 'running'", [.date(Date())])
        return db.changes
    }

    // MARK: Trials

    func trialInfo(_ r: Row) -> TrialInfo {
        TrialInfo(
            id: r.string("id") ?? "", runId: r.string("run_id") ?? "", variantKey: r.string("variant_key") ?? "",
            index: Int(r.int("idx") ?? 0), order: Int(r.int("ord") ?? 0), status: TrialStatus(rawValue: r.string("status") ?? "") ?? .pending,
            sessionId: r.string("session_id"), workdir: r.string("workdir"), startedAt: r.date("started_at"), finishedAt: r.date("finished_at"),
            manifest: decode(TrialManifest.self, r.string("manifest")), facts: decode(TrialFacts.self, r.string("facts")),
            signals: decode(TrialSignals.self, r.string("signals")), error: r.string("error"))
    }

    public func trials(runId: String) throws -> [TrialInfo] {
        try db.query("SELECT * FROM trials WHERE run_id = ? ORDER BY ord", [.text(runId)]).map(trialInfo)
    }

    public func trial(id: String) throws -> TrialInfo? {
        try db.query("SELECT * FROM trials WHERE id = ?", [.text(id)]).first.map(trialInfo)
    }

    public func trialStarted(id: String, sessionId: String, workdir: String, manifest: TrialManifest) throws {
        try db.run(
            "UPDATE trials SET status = 'running', session_id = ?, workdir = ?, manifest = ?, started_at = ? WHERE id = ?",
            [.text(sessionId), .text(workdir), .text(json(manifest)), .date(Date()), .text(id)])
    }

    public func trialFinished(id: String, status: TrialStatus, facts: TrialFacts?, signals: TrialSignals?, error: String?, transcriptBlob: String?) throws {
        try db.run(
            "UPDATE trials SET status = ?, facts = ?, signals = ?, error = ?, transcript_blob = ?, finished_at = ? WHERE id = ?",
            [
                .text(status.rawValue), facts.map { .text(json($0)) } ?? .null, signals.map { .text(json($0)) } ?? .null,
                .optional(error), .optional(transcriptBlob), .date(Date()), .text(id),
            ])
    }

    public func updateTrialSignals(id: String, signals: TrialSignals) throws {
        try db.run("UPDATE trials SET signals = ? WHERE id = ?", [.text(json(signals)), .text(id)])
    }

    public func trialTranscript(id: String) throws -> String? {
        guard let blob = try db.query("SELECT transcript_blob FROM trials WHERE id = ?", [.text(id)]).first?.string("transcript_blob") else { return nil }
        return try blobs.getString(blob)
    }

    /// Mean Claude Code cost of finished trials for the same model, used by estimates.
    public func historicalTrialCost(model: String?) throws -> (mean: Double, n: Int)? {
        var costs: [Double] = []
        for r in try db.query("SELECT facts, manifest FROM trials WHERE status = 'succeeded' ORDER BY finished_at DESC LIMIT 200") {
            guard let f = decode(TrialFacts.self, r.string("facts")), let c = f.claudeCostUSD else { continue }
            let m = decode(TrialManifest.self, r.string("manifest"))?.model
            if m == model { costs.append(c) }
        }
        guard !costs.isEmpty else { return nil }
        return (costs.reduce(0, +) / Double(costs.count), costs.count)
    }
}
