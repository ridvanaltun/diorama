import DioramaCore
import DioramaEngine
import DioramaRunner
import DioramaStore
import Foundation

/// `/api/v1/…` — the local control API used by the CLI and the app. Requires the bearer
/// token from `daemon.json`.
struct ControlAPI: Sendable {
    let daemon: DioramaDaemon

    struct Failure: Error {
        let status: Int
        let message: String
    }

    func handle(_ req: HTTPRequest, _ writer: ResponseWriter) async {
        let parts = req.path.split(separator: "/").map(String.init)  // ["api","v1",...]
        let route = Array(parts.dropFirst(2))
        do {
            if route == ["events", "stream"], req.method == "GET" {
                await streamEvents(req, writer)
                return
            }
            let (status, body) = try await dispatch(req.method, route, req)
            try? await writer.send(status, [("content-type", "application/json"), ("cache-control", "no-store")], body)
        } catch let f as Failure {
            await error(writer, f.status, f.message)
        } catch let e as StoreError {
            await error(writer, 400, e.description)
        } catch let e as RunnerError {
            await error(writer, 400, e.description)
        } catch let e as DecodingError {
            await error(writer, 400, "invalid request body: \(e)")
        } catch let other {
            await error(writer, 500, String(describing: other))
        }
    }

    func error(_ writer: ResponseWriter, _ status: Int, _ message: String) async {
        let body = (try? DioramaCoding.encoder.encode(APIErrorBody(error: message))).map(Array.init) ?? []
        try? await writer.send(status, [("content-type", "application/json")], body)
    }

    func ok<T: Encodable>(_ value: T, status: Int = 200) throws -> (Int, [UInt8]) {
        (status, Array(try DioramaCoding.encoder.encode(value)))
    }

    func decode<T: Decodable>(_ type: T.Type, _ req: HTTPRequest) throws -> T {
        try DioramaCoding.decoder.decode(type, from: Data(req.body))
    }

    func notFound(_ what: String) -> Failure { Failure(status: 404, message: "\(what) not found") }

    /// Matches `pattern` (segments, `:x` captures) against the route; returns captures.
    static func match(_ method: String, _ route: [String], _ m: String, _ pattern: String) -> [String]? {
        guard method == m else { return nil }
        let segs = pattern.split(separator: "/").map(String.init)
        guard segs.count == route.count else { return nil }
        var caps: [String] = []
        for (a, b) in zip(segs, route) {
            // Clients percent-encode captures (profile names can contain spaces).
            if a.hasPrefix(":") { caps.append(b.removingPercentEncoding ?? b) } else if a != b { return nil }
        }
        return caps
    }

    func dispatch(_ method: String, _ route: [String], _ req: HTTPRequest) async throws -> (Int, [UInt8]) {
        let store = daemon.store
        if Self.match(method, route, "GET", "health") != nil {
            return try ok(daemon.health())
        }
        if Self.match(method, route, "GET", "settings") != nil {
            return try ok(store.settings())
        }
        if Self.match(method, route, "PUT", "settings") != nil {
            var s = try decode(DioramaSettings.self, req)
            // Pausing has its own endpoints; a settings save (possibly from an older draft) never changes it.
            s.steeringPaused = store.settings().steeringPaused
            s.folderProfiles = store.settings().folderProfiles
            s.profileFolders = store.settings().profileFolders
            guard s.retentionDays >= 1, s.retentionDays <= 3650 else { throw Failure(status: 400, message: "retentionDays must be 1–3650") }
            if let b = s.dailyBudgetUSD, !(b >= 0) { throw Failure(status: 400, message: "dailyBudgetUSD must be zero or more") }
            try store.saveSettings(s)
            daemon.sessions.settingsChanged()
            return try ok(s)
        }
        if Self.match(method, route, "GET", "key") != nil {
            return try ok(daemon.keyStatus())
        }
        if Self.match(method, route, "PUT", "key") != nil {
            let k = try decode(SetKeyRequest.self, req).key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard k.count >= 20, !k.contains(where: \.isWhitespace) else { throw Failure(status: 400, message: "that does not look like an Anthropic API key") }
            try daemon.secrets.set(k)
            return try ok(daemon.keyStatus())
        }
        if Self.match(method, route, "DELETE", "key") != nil {
            try daemon.secrets.delete()
            return try ok(daemon.keyStatus())
        }
        if Self.match(method, route, "GET", "templates") != nil {
            return try ok(RuleTemplates.all)
        }
        if Self.match(method, route, "GET", "profiles") != nil {
            return try ok(store.profiles())
        }
        if Self.match(method, route, "POST", "profiles") != nil {
            return try ok(store.createProfile(try decode(Profile.self, req)), status: 201)
        }
        if let c = Self.match(method, route, "POST", "profiles/:id/tests") {
            guard let current = try store.resolveProfile(c[0]) else { throw notFound("profile") }
            let r = try decode(AddRuleTestRequest.self, req)
            var profile = current.profile
            let test: ProfileTestCase
            do { test = try daemon.ruleTest(fromDecision: r.decisionId, profile: profile, name: r.name) } catch let e as StoreError { throw Failure(status: 404, message: e.description) }
            profile.tests = (profile.tests ?? []).filter { $0.id != test.id } + [test]
            _ = try store.updateProfile(id: current.profileId, profile)
            return try ok(try profileDetail(current.profileId))
        }
        if let c = Self.match(method, route, "GET", "profiles/:id/stats") {
            guard let current = try store.resolveProfile(c[0]) else { throw notFound("profile") }
            let days = Int(req.query["days"] ?? "") ?? 30
            let since = days > 0 ? Calendar.current.date(byAdding: .day, value: -days, to: Date()) : nil
            guard let stats = try store.ruleStats(profileId: current.profileId, since: since, includeTrials: req.query["trials"] == "1") else { throw notFound("profile") }
            return try ok(stats)
        }
        if let c = Self.match(method, route, "GET", "profiles/:id") {
            let id = c[0]
            return try ok(try profileDetail(id))
        }
        if let c = Self.match(method, route, "PUT", "profiles/:id") {
            let id = c[0]
            guard let current = try store.resolveProfile(id) else { throw notFound("profile") }
            _ = try store.updateProfile(id: current.profileId, try decode(Profile.self, req))
            return try ok(try profileDetail(current.profileId))
        }
        if let c = Self.match(method, route, "DELETE", "profiles/:id") {
            let id = c[0]
            guard let current = try store.resolveProfile(id) else { throw notFound("profile") }
            try store.archiveProfile(id: current.profileId)
            return try ok(["archived": current.profileId])
        }
        if Self.match(method, route, "GET", "sessions") != nil {
            let kind = req.query["kind"].flatMap(SessionKind.init(rawValue:))
            let tag = req.query["tag"].flatMap { $0.isEmpty ? nil : $0 }
            let archived = req.query["archived"].flatMap(Store.ArchiveFilter.init(rawValue:)) ?? .hide
            return try ok(try store.sessions(kind: kind, tag: tag, archived: archived, limit: Int(req.query["limit"] ?? "") ?? 200).map(store.info))
        }
        if let c = Self.match(method, route, "POST", "sessions/:id/rules/:rule/off") ?? Self.match(method, route, "POST", "sessions/:id/rules/:rule/on") {
            guard let s = try store.session(id: c[0]) else { throw notFound("session") }
            guard s.trialId == nil else { throw Failure(status: 400, message: "experiment trials always run their full configuration") }
            // By id, by name, or "session-prompt".
            let rules = s.profileVersion?.profile.rules ?? []
            guard let id = c[1] == "session-prompt" && s.prompt != nil ? "session-prompt" : (rules.first { $0.id == c[1] } ?? rules.first { $0.name == c[1] })?.id else {
                throw Failure(status: 404, message: "this session has no rule '\(c[1])'")
            }
            try store.setRuleDisabled(sessionId: s.id, ruleId: id, route.last == "off")
            return try ok(try store.info(try store.session(id: s.id)!))
        }
        if Self.match(method, route, "POST", "sessions/archive") != nil {
            let r = try decode(ArchiveRequest.self, req)
            var ids = r.sessionIds
            if let days = r.olderThanDays, r.archived, let cutoff = Calendar.current.date(byAdding: .day, value: -max(days, 0), to: Date()) {
                ids += try store.endedSessions(before: cutoff, kind: r.kind)
            }
            let changed = try store.setArchived(sessionIds: ids, r.archived)
            if changed > 0 { store.addEvent(sessionId: nil, kind: .sessionEnded, message: "\(r.archived ? "Archived" : "Unarchived") \(changed) session(s)") }
            return try ok(["changed": changed])
        }
        if Self.match(method, route, "GET", "session-tags") != nil {
            return try ok(try store.sessionTags())
        }
        if let c = Self.match(method, route, "PUT", "sessions/:id/annotations") {
            guard try store.session(id: c[0]) != nil else { throw notFound("session") }
            do { try store.annotate(sessionId: c[0], try decode(SessionAnnotations.self, req)) } catch let e as StoreError { throw Failure(status: 400, message: e.description) }
            return try ok(try store.info(try store.session(id: c[0])!))
        }
        if Self.match(method, route, "POST", "sessions") != nil {
            return try ok(try daemon.createSession(try decode(SessionSpec.self, req)), status: 201)
        }
        if let c = Self.match(method, route, "GET", "sessions/:id") {
            let id = c[0]
            guard let s = try store.session(id: id) else { throw notFound("session") }
            return try ok(try store.info(s))
        }
        if let c = Self.match(method, route, "POST", "sessions/:id/pause") ?? Self.match(method, route, "POST", "sessions/:id/resume") {
            let id = c[0]
            guard try store.session(id: id) != nil else { throw notFound("session") }
            try store.setPaused(sessionId: id, route.last == "pause")
            return try ok(try store.info(try store.session(id: id)!))
        }
        if Self.match(method, route, "GET", "export/decisions") != nil {
            let format = DataExport.Format(rawValue: req.query["format"] ?? "csv") ?? .csv
            var filter = DecisionExportFilter(includeTrials: req.query["trials"] != "0", rewrittenOnly: req.query["rewritten"] == "1", includeTexts: req.query["texts"] == "1")
            if let days = Int(req.query["days"] ?? ""), days > 0 { filter.since = Calendar.current.date(byAdding: .day, value: -days, to: Date()) }
            filter.sessionId = req.query["session"].flatMap { $0.isEmpty ? nil : $0 }
            if let p = req.query["profile"], !p.isEmpty {
                guard let v = try store.resolveProfile(p) else { throw notFound("profile") }
                filter.profileId = v.profileId
            }
            let rows = try store.exportDecisions(filter)
            return try ok(DecisionExport(format: format, rows: rows.count, content: DataExport.render(rows, format: format, includeTexts: filter.includeTexts)))
        }
        if Self.match(method, route, "POST", "profile-tests") != nil {
            let r = try decode(ProfileTestRequest.self, req)
            if let p = r.profile { return try ok(ProfileTests.run(p)) }
            guard let ref = r.profileRef, let v = try store.resolveProfile(ref) else { throw notFound("profile") }
            return try ok(ProfileTests.run(v.profile))
        }
        if Self.match(method, route, "GET", "profile-folders") != nil {
            return try ok(store.profileFolderStatus(store.settings().profileFolders))
        }
        if Self.match(method, route, "POST", "profile-folders/sync") != nil {
            return try ok(store.syncProfileFolders(store.settings().profileFolders))
        }
        if Self.match(method, route, "POST", "profile-folders/add") != nil || Self.match(method, route, "POST", "profile-folders/remove") != nil {
            let f = try decode(FolderDefault.self, req)
            let path = FolderDefault.normalize(f.path)
            var s = store.settings()
            if route.last == "add" {
                var isDir: ObjCBool = false
                guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
                    throw Failure(status: 400, message: "\(path) isn't a folder")
                }
                if !s.profileFolders.contains(path) { s.profileFolders.append(path) }
            } else {
                s.profileFolders.removeAll { $0 == path }
            }
            try store.saveSettings(s)
            return try ok(store.syncProfileFolders(s.profileFolders))
        }
        if let c = Self.match(method, route, "POST", "profiles/:id/write-file") {
            guard let current = try store.resolveProfile(c[0]) else { throw notFound("profile") }
            do { return try ok(["path": try store.writeProfileToFile(profileId: current.profileId)]) } catch let e as StoreError { throw Failure(status: 400, message: e.description) }
        }
        if Self.match(method, route, "GET", "folders") != nil {
            if let path = req.query["path"], !path.isEmpty { return try ok(store.settings().folderDefault(for: path).map { [$0] } ?? []) }
            return try ok(store.settings().folderProfiles.map { FolderDefault(path: $0.key, profile: $0.value) }.sorted { $0.path < $1.path })
        }
        if Self.match(method, route, "PUT", "folders") != nil {
            let f = try decode(FolderDefault.self, req)
            let path = FolderDefault.normalize(f.path)
            guard path.hasPrefix("/"), path != "/" else { throw Failure(status: 400, message: "give an absolute project folder") }
            var s = store.settings()
            if let p = f.profile, !p.isEmpty {
                guard try store.resolveProfile(p) != nil else { throw notFound("profile") }
                s.folderProfiles[path] = p
            } else {
                s.folderProfiles[path] = nil
            }
            try store.saveSettings(s)
            daemon.sessions.settingsChanged()
            return try ok(FolderDefault(path: path, profile: s.folderProfiles[path]))
        }
        if Self.match(method, route, "GET", "spend/history") != nil {
            let days = min(max(Int(req.query["days"] ?? "") ?? 30, 1), 366)
            return try ok(try store.spendHistory(days: days))
        }
        if Self.match(method, route, "GET", "reviews") != nil {
            return try ok(await daemon.engine.reviews.pending)
        }
        if let c = Self.match(method, route, "POST", "reviews/:id/approve") ?? Self.match(method, route, "POST", "reviews/:id/reject") {
            let verdict: ReviewVerdict = route.last == "approve" ? .approved : .rejected
            guard await daemon.engine.reviews.resolve(c[0], verdict) else {
                throw Failure(status: 409, message: "nothing is waiting for review under \(c[0]) (already answered or timed out)")
            }
            return try ok(["id": c[0], "verdict": verdict.rawValue])
        }
        if Self.match(method, route, "POST", "steering/pause") != nil || Self.match(method, route, "POST", "steering/resume") != nil {
            var s = store.settings()
            let pause = route.last == "pause"
            if s.steeringPaused != pause {
                s.steeringPaused = pause
                try store.saveSettings(s)
                daemon.sessions.settingsChanged()
                store.addEvent(sessionId: nil, kind: .warning, message: pause ? "Steering paused everywhere: tool results reach Claude unchanged (redaction still applies)" : "Steering resumed everywhere")
            }
            return try ok(s)
        }
        if let c = Self.match(method, route, "POST", "sessions/:id/end") {
            let id = c[0]
            guard try store.session(id: id) != nil else { throw notFound("session") }
            try store.endSession(id: id)
            return try ok(try store.info(try store.session(id: id)!))
        }
        if let c = Self.match(method, route, "GET", "sessions/:id/report") {
            let report = try SessionReport.build(sessionId: c[0], store: store)
            let format = req.query["format"] ?? "md"
            guard format == "md" || format == "html" else { throw Failure(status: 400, message: "unknown report format '\(format)' (use md or html)") }
            return try ok(["format": format, "content": format == "html" ? report.html() : report.markdown()])
        }
        if let c = Self.match(method, route, "GET", "sessions/:id/experiment-draft") {
            return try ok(try daemon.experimentDraft(sessionId: c[0], trialsPerVariant: Int(req.query["trials"] ?? "") ?? 5))
        }
        if let c = Self.match(method, route, "GET", "sessions/:id/impact") {
            guard try store.session(id: c[0]) != nil else { throw notFound("session") }
            return try ok(try daemon.impact(sessionId: c[0]))
        }
        if let c = Self.match(method, route, "GET", "sessions/:id/timeline") {
            let id = c[0]
            guard let s = try store.session(id: id) else { throw notFound("session") }
            let after = Int64(req.query["after"] ?? "") ?? 0
            return try ok(Timeline(
                session: try store.info(s), exchanges: try store.exchanges(sessionId: id, afterId: after),
                decisions: try store.decisions(sessionId: id).map(\.summary), events: try store.events(sessionId: id)))
        }
        if Self.match(method, route, "GET", "search") != nil {
            let q = req.query["q"] ?? ""
            let limit = min(max(Int(req.query["limit"] ?? "") ?? 50, 1), 200)
            return try ok(try store.search(q, rewrittenOnly: req.query["rewritten"] == "1", sessionId: req.query["session"], limit: limit))
        }
        if Self.match(method, route, "GET", "spend") != nil {
            return try ok(try daemon.spendSummary())
        }
        if Self.match(method, route, "POST", "whatif") != nil {
            return try ok(try await daemon.whatIf(try decode(WhatIfRequest.self, req)))
        }
        if Self.match(method, route, "POST", "playground") != nil {
            return try ok(try await daemon.playground(try decode(PlaygroundRequest.self, req)))
        }
        if Self.match(method, route, "GET", "decisions") != nil {
            let limit = min(max(Int(req.query["limit"] ?? "") ?? 50, 1), 500)
            return try ok(try store.recentDecisions(limit: limit).map { RecentToolResult(decision: $0.0.summary, sessionName: $0.1) })
        }
        if Self.match(method, route, "POST", "hook") != nil {
            return try ok(try await daemon.handleHook(try decode(HookEvent.self, req)))
        }
        if let c = Self.match(method, route, "GET", "decisions/:id") {
            let id = c[0]
            guard let d = try store.decisionDetail(toolUseId: id) else { throw notFound("decision") }
            return try ok(d)
        }
        if let c = Self.match(method, route, "GET", "exchanges/:id") {
            let id = c[0]
            guard let i = Int64(id), let e = try store.exchange(id: i) else { throw notFound("exchange") }
            return try ok(e)
        }
        if let c = Self.match(method, route, "GET", "exchanges/:id/raw") {
            let id = c[0]
            guard let i = Int64(id), let r = try store.exchangeRaw(id: i) else { throw notFound("exchange") }
            return try ok(ExchangeRawPayload(request: r.request, forwarded: r.forwarded, response: r.response, requestHeaders: r.requestHeaders, responseHeaders: r.responseHeaders))
        }
        if Self.match(method, route, "GET", "events") != nil {
            return try ok(try store.events(sessionId: req.query["session"], afterId: Int64(req.query["after"] ?? "") ?? 0))
        }
        if Self.match(method, route, "GET", "doctor") != nil {
            return try ok(daemon.doctor())
        }
        if Self.match(method, route, "POST", "maintenance/retention") != nil {
            let r = try store.applyRetention(days: store.settings().retentionDays)
            return try ok(MaintenanceResult(exchangesCleared: r.cleared, blobsRemoved: r.blobsRemoved, blobBytes: store.blobs.totalBytes()))
        }
        if Self.match(method, route, "POST", "shutdown") != nil {
            Task { try? await Task.sleep(for: .milliseconds(100)); await daemon.stop() }
            return try ok(["status": "stopping"])
        }
        // Experiments
        if Self.match(method, route, "GET", "experiments") != nil {
            return try ok(try store.experiments())
        }
        if Self.match(method, route, "POST", "experiments") != nil {
            return try ok(try daemon.runner.create(try decode(ExperimentDefinition.self, req)), status: 201)
        }
        if let c = Self.match(method, route, "GET", "experiments/:id") {
            let id = c[0]
            guard let e = try store.experiment(id: id) else { throw notFound("experiment") }
            return try ok(e)
        }
        if let c = Self.match(method, route, "GET", "experiments/:id/comparison") {
            let runs = req.query["runs"].map { $0.split(separator: ",").map(String.init) }
            return try ok(try daemon.runner.pooledComparison(experimentId: c[0], runIds: runs))
        }
        if let c = Self.match(method, route, "GET", "experiments/:id/report") {
            let runs = req.query["runs"].map { $0.split(separator: ",").map(String.init) }
            let text = try daemon.runner.pooledReport(experimentId: c[0], runIds: runs, format: req.query["format"] ?? "md")
            return try ok(["format": req.query["format"] ?? "md", "content": text])
        }
        if let c = Self.match(method, route, "POST", "experiments/:id/runs") {
            let id = c[0]
            return try ok(try daemon.runner.prepareRun(experimentId: id), status: 201)
        }
        if let c = Self.match(method, route, "GET", "runs/:id") {
            let id = c[0]
            guard let r = try store.run(id: id) else { throw notFound("run") }
            return try ok(r)
        }
        if let c = Self.match(method, route, "POST", "runs/:id/start") {
            let id = c[0]
            return try ok(try daemon.runner.start(runId: id, confirmationToken: try decode(StartRunRequest.self, req).confirmationToken))
        }
        if let c = Self.match(method, route, "POST", "runs/:id/cancel") {
            let id = c[0]
            try daemon.runner.cancel(runId: id)
            guard let r = try store.run(id: id) else { throw notFound("run") }
            return try ok(r)
        }
        if let c = Self.match(method, route, "GET", "runs/:id/comparison") {
            let id = c[0]
            return try ok(try daemon.runner.comparison(runId: id))
        }
        if let c = Self.match(method, route, "GET", "runs/:id/report") {
            let id = c[0]
            let text = try daemon.runner.report(runId: id, format: req.query["format"] ?? "md")
            return try ok(["format": req.query["format"] ?? "md", "content": text])
        }
        if let c = Self.match(method, route, "GET", "trials/:id/transcript") {
            let id = c[0]
            guard let t = try store.trialTranscript(id: id) else { throw notFound("transcript") }
            return try ok(["content": t])
        }
        throw Failure(status: 404, message: "no route for \(method) /api/v1/\(route.joined(separator: "/"))")
    }

    func profileDetail(_ id: String) throws -> ProfileDetail {
        let store = daemon.store
        guard let current = try store.resolveProfile(id),
              let summary = try store.profiles(includeArchived: true).first(where: { $0.id == current.profileId })
        else { throw notFound("profile") }
        var d = ProfileDetail(summary: summary, current: current, versions: try store.profileVersions(profileId: current.profileId))
        d.syncedFile = store.syncedFile(profileId: current.profileId)
        return d
    }

    /// Server-sent events of live activity, optionally filtered to one session.
    func streamEvents(_ req: HTTPRequest, _ writer: ResponseWriter) async {
        let filter = req.query["session"]
        let (id, stream) = daemon.hub.subscribe()
        defer { daemon.hub.unsubscribe(id) }
        do {
            try await writer.head(200, [("content-type", "text/event-stream"), ("cache-control", "no-store")])
            try await writer.body(Array(": connected\n\n".utf8))
            for await ev in stream {
                if ev.id == -1 {
                    try await writer.body(Array(": ping\n\n".utf8))
                    continue
                }
                if let filter, ev.sessionId != filter, ev.sessionId != nil { continue }
                let data = try DioramaCoding.encoder.encode(ev)
                try await writer.body(Array("event: \(ev.kind.rawValue)\ndata: ".utf8) + Array(data) + Array("\n\n".utf8))
            }
            try await writer.end()
        } catch {
            // client disconnected
        }
    }
}
