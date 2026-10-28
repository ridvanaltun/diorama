import DioramaClient
import DioramaCore
import DioramaEngine
import DioramaStore
import DioramaTestSupport
import Foundation
import Testing
@testable import DioramaGateway

// MARK: - Harness

final class TestEnv: @unchecked Sendable {
    let home: URL
    let mock: MockUpstream
    let daemon: DioramaDaemon
    let client: ControlClient
    let serveTask: Task<Void, Never>
    var port: Int { daemon.port }

    static func start(provider: RewriteProvider = ScriptedRewriteProvider.replacing("Example Domain", with: "Morph Test Domain"),
                      home: URL? = nil, mock: MockUpstream? = nil, cliPath: String? = nil) async throws -> TestEnv {
        let home = home ?? FileManager.default.temporaryDirectory.appendingPathComponent("diorama-gw-\(UUID().uuidString)")
        let mock = mock ?? MockUpstream()
        if mock.port == 0 { try await mock.start() }
        var o = DioramaDaemon.Options(paths: DioramaPaths(home: home))
        o.claudeUserSettings = home.appendingPathComponent("claude-user-settings.json")
        o.port = 0
        o.upstream = mock.url
        o.providerOverride = provider
        o.secrets = MemorySecretStore("sk-ant-test-key-not-real-000000")
        o.cliPath = cliPath
        let d = try DioramaDaemon(options: o)
        _ = try await d.start()
        let task = Task { _ = try? await d.run() }
        let info = try #require(DaemonInfo.read(from: DioramaPaths(home: home).daemonInfo))
        return TestEnv(home: home, mock: mock, daemon: d, client: ControlClient(info: info), serveTask: task)
    }

    init(home: URL, mock: MockUpstream, daemon: DioramaDaemon, client: ControlClient, serveTask: Task<Void, Never>) {
        self.home = home
        self.mock = mock
        self.daemon = daemon
        self.client = client
        self.serveTask = serveTask
    }

    func stop(keepMock: Bool = false) async {
        await daemon.stop()
        serveTask.cancel()
        if !keepMock { await mock.stop() }
    }

    func post(_ token: String, _ path: String = "/v1/messages?beta=true", body: [UInt8], headers: [String: String] = [:]) async throws -> (Int, [String: String], Data) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/s/\(token)\(path)")!)
        req.httpMethod = "POST"
        req.httpBody = Data(body)
        var h = ["content-type": "application/json", "anthropic-version": "2023-06-01", "anthropic-beta": "oauth-2025-04-20,claude-code-20250219", "authorization": "Bearer user-oauth-token", "x-claude-code-session-id": "cc-session-1"]
        h.merge(headers) { _, b in b }
        for (k, v) in h { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = resp as! HTTPURLResponse
        var out: [String: String] = [:]
        for (k, v) in http.allHeaderFields { out[(k as! String).lowercased()] = v as? String }
        return (http.statusCode, out, data)
    }
}

/// Sends a raw HTTP/1.1 request (lets tests control Host/Origin) and returns the response text.
/// A raw HTTP/1.1 exchange over a socket. It waits on a GCD thread: the daemon answering it runs in
/// this process, on the cooperative pool a blocking `recv` would hold.
func rawHTTP(port: Int, _ request: String) async throws -> String {
    try await offloadBlocking { try rawHTTPBlocking(port: port, request) }
}

func rawHTTPBlocking(port: Int, _ request: String) throws -> String {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(UInt16(port).bigEndian)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    guard rc == 0 else { throw ClientError("connect failed") }
    var tv = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    _ = request.withCString { send(fd, $0, strlen($0), 0) }
    var out = [UInt8]()
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = recv(fd, &buf, buf.count, 0)
        if n <= 0 { break }
        out += buf[0..<n]
    }
    return String(decoding: out, as: UTF8.self)
}

func sampleBody(results: [(id: String, text: String)] = [("toolu_x", "Example Domain page")]) -> [UInt8] {
    var msgs = [#"{"role":"user","content":"fetch it"}"#]
    for r in results {
        msgs.append(#"{"role":"assistant","content":[{"type":"tool_use","id":"\#(r.id)","name":"WebFetch","input":{"url":"https://example.com","prompt":"p"}}]}"#)
        msgs.append(#"{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(r.id)","content":"\#(r.text)"}]}"#)
    }
    return Array(#"{"model":"claude-opus-5-5","max_tokens":1000,"stream":true,"messages":[\#(msgs.joined(separator: ","))],"context_management":{"edits":[]}}"#.utf8)
}

// MARK: - Tests

@Suite(.serialized) struct GatewayTests {
    @Test func passThroughIsByteIdenticalAndStreamsBack() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        let launch = try await env.client.createSession(SessionSpec(name: "plain", cwd: "/tmp"))
        #expect(launch.environment["ANTHROPIC_BASE_URL"] == launch.baseURL)
        #expect(launch.claudeArguments.first == "--settings")
        let body = sampleBody()
        let (status, headers, data) = try await env.post(launch.token, body: body)
        #expect(status == 200)
        #expect(headers["content-type"]?.contains("text/event-stream") == true)
        #expect(headers["request-id"] == "req_mock")
        #expect(String(decoding: data, as: UTF8.self) == MockUpstream.sseEvents().joined())
        let upstream = try #require(env.mock.requests.last)
        #expect(upstream.body == body)
        #expect(upstream.uri == "/v1/messages?beta=true")
        #expect(upstream.header("anthropic-beta") == "oauth-2025-04-20,claude-code-20250219")
        #expect(upstream.header("authorization") == "Bearer user-oauth-token")
        #expect(upstream.header("x-claude-code-session-id") == "cc-session-1")

        let tl = try await env.client.timeline(launch.session.id)
        let ex = try #require(tl.exchanges.first)
        #expect(ex.status == 200)
        #expect(ex.usage?.cacheReadTokens == 100)
        #expect(ex.usage?.outputTokens == 5)
        #expect(ex.assistant?.text == "Hello")
        #expect(ex.toolResults.map(\.handling) == [.decidedUnchanged])
        #expect(tl.session.claudeSessionIds == ["cc-session-1"])
        // Credentials never stored.
        let raw = try await env.client.exchangeRaw(ex.id)
        #expect(raw.requestHeaders?.contains("user-oauth-token") == false)
        #expect(raw.requestHeaders?.contains("<redacted>") == true)
    }

    @Test func rewritesThroughGatewayAndReplays() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        _ = try await env.client.createProfile(Profile(name: "web", rules: [Rule(name: "r", match: RuleMatch(tools: ["WebFetch"]), instructions: "rename")]))
        let launch = try await env.client.createSession(SessionSpec(name: "steered", cwd: "/tmp", profile: "web"))
        _ = try await env.post(launch.token, body: sampleBody())
        let first = try #require(env.mock.requests.last)
        #expect(String(decoding: first.body, as: UTF8.self) == String(decoding: sampleBody(), as: UTF8.self).replacingOccurrences(of: "Example Domain page", with: "Morph Test Domain page"))
        let turn2 = sampleBody(results: [("toolu_x", "Example Domain page"), ("toolu_y", "nothing here")])
        _ = try await env.post(launch.token, body: turn2)
        let second = String(decoding: try #require(env.mock.requests.last).body, as: UTF8.self)
        #expect(second.contains("Morph Test Domain page"))
        #expect(!second.contains("Example Domain page"))
        let detail = try await env.client.decision("toolu_x")
        #expect(detail.summary.outcome == .rewritten)
        #expect(detail.originalText == "Example Domain page")
        #expect(detail.replacementText == "Morph Test Domain page")
        #expect(detail.summary.replayCount == 1)
        #expect(detail.followUp?.text == "Hello")
        let tl = try await env.client.timeline(launch.session.id)
        #expect(tl.exchanges.last?.toolResults.map(\.handling) == [.replayedRewritten, .decidedUnchanged])
        #expect(tl.session.stats.rewrites == 1)
    }

    @Test func sessionsAreIsolated() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        _ = try await env.client.createProfile(Profile(name: "web", rules: [Rule(name: "r", match: RuleMatch(tools: ["WebFetch"]), instructions: "rename")]))
        let steered = try await env.client.createSession(SessionSpec(name: "a", cwd: "/tmp", profile: "web"))
        let plain = try await env.client.createSession(SessionSpec(name: "b", cwd: "/tmp"))
        _ = try await env.post(plain.token, body: sampleBody(results: [("toolu_p1", "Example Domain")]))
        #expect(String(decoding: try #require(env.mock.requests.last).body, as: UTF8.self).contains("Example Domain"))
        _ = try await env.post(steered.token, body: sampleBody(results: [("toolu_s1", "Example Domain")]))
        #expect(String(decoding: try #require(env.mock.requests.last).body, as: UTF8.self).contains("Morph Test Domain"))
        #expect(try await env.client.timeline(plain.session.id).exchanges.count == 1)
        #expect(try await env.client.timeline(steered.session.id).exchanges.count == 1)
    }

    @Test func rejectsUnknownTokensBadHostsOriginsAndMissingControlAuth() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        let (status, headers, _) = try await env.post(String(repeating: "a", count: 32), body: sampleBody())
        #expect(status == 403)
        #expect(headers["x-should-retry"] == "false")
        #expect(env.mock.requests.isEmpty)

        let launch = try await env.client.createSession(SessionSpec(name: "x", cwd: "/tmp"))
        let badHost = try await rawHTTP(port: env.port, "GET /s/\(launch.token)/v1/models HTTP/1.1\r\nHost: evil.example:80\r\nConnection: close\r\n\r\n")
        #expect(badHost.hasPrefix("HTTP/1.1 403"))
        let origin = try await rawHTTP(port: env.port, "GET /api/v1/health HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: https://evil.example\r\nAuthorization: Bearer \(env.client.info.controlToken)\r\nConnection: close\r\n\r\n")
        #expect(origin.hasPrefix("HTTP/1.1 403"))
        let noAuth = try await rawHTTP(port: env.port, "GET /api/v1/health HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
        #expect(noAuth.hasPrefix("HTTP/1.1 401"))
        let ok = try await rawHTTP(port: env.port, "GET /api/v1/health HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer \(env.client.info.controlToken)\r\nConnection: close\r\n\r\n")
        #expect(ok.hasPrefix("HTTP/1.1 200"))
        #expect(env.mock.requests.isEmpty)
    }

    @Test func forwardsUpstreamErrorsAndReportsUnreachableUpstream() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        let launch = try await env.client.createSession(SessionSpec(name: "e", cwd: "/tmp"))
        env.mock.setHandler { _ in
            .json(#"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#, status: 429, headers: [("retry-after", "7"), ("x-should-retry", "true"), ("anthropic-ratelimit-unified-status", "rejected")])
        }
        let (s, h, d) = try await env.post(launch.token, body: sampleBody())
        #expect(s == 429)
        #expect(h["retry-after"] == "7")
        #expect(h["x-should-retry"] == "true")
        #expect(h["anthropic-ratelimit-unified-status"] == "rejected")
        #expect(String(decoding: d, as: UTF8.self).contains("slow down"))
        let ex = try #require(try await env.client.timeline(launch.session.id).exchanges.last)
        #expect(ex.status == 429)
        #expect(ex.error == "slow down")

        await env.mock.stop()
        let (s2, h2, d2) = try await env.post(launch.token, body: sampleBody())
        #expect(s2 == 502)
        #expect(h2["x-should-retry"] == "true")
        #expect(String(decoding: d2, as: UTF8.self).contains("could not reach the upstream"))
    }

    @Test func streamsIncrementallyWithoutBuffering() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        let launch = try await env.client.createSession(SessionSpec(name: "s", cwd: "/tmp"))
        env.mock.setHandler { _ in .sse(MockUpstream.sseEvents(), delay: .milliseconds(150)) }
        var req = URLRequest(url: URL(string: "\(launch.baseURL)/v1/messages")!)
        req.httpMethod = "POST"
        req.httpBody = Data(sampleBody())
        let start = Date()
        let (bytes, _) = try await URLSession.shared.bytes(for: req)
        var firstLineAt: TimeInterval?
        var lines = 0
        for try await _ in bytes.lines {
            if firstLineAt == nil { firstLineAt = Date().timeIntervalSince(start) }
            lines += 1
        }
        let total = Date().timeIntervalSince(start)
        #expect(lines > 10)
        #expect(total > 0.9)
        #expect(try #require(firstLineAt) < total - 0.5)
    }

    @Test func handlesLargeGzipAndCountTokensBodies() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        _ = try await env.client.createProfile(Profile(name: "web", rules: [Rule(name: "r", match: RuleMatch(tools: ["WebFetch"]), instructions: "rename")]))
        let launch = try await env.client.createSession(SessionSpec(name: "big", cwd: "/tmp", profile: "web"))
        env.mock.setHandler { _ in .json(#"{"input_tokens":1234}"#) }
        // ~20 MB body with a large unrelated system prompt.
        let filler = String(repeating: "x", count: 20_000_000)
        let big = Array(#"{"model":"m","system":"\#(filler)","messages":[{"role":"user","content":"hi"},{"role":"assistant","content":[{"type":"tool_use","id":"toolu_big","name":"WebFetch","input":{"url":"u"}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_big","content":"Example Domain"}]}]}"#.utf8)
        let (s, _, _) = try await env.post(launch.token, "/v1/messages/count_tokens?beta=true", body: big)
        #expect(s == 200)
        let fwd = try #require(env.mock.requests.last)
        #expect(fwd.body.count == big.count + 3)  // "Morph Test Domain" is 3 bytes longer than "Example Domain"
        #expect(fwd.uri == "/v1/messages/count_tokens?beta=true")

        // gzip-encoded request: decoded for inspection, re-sent uncompressed when modified.
        let plain = sampleBody(results: [("toolu_gz", "Example Domain")])
        let gz = try gzip(plain)
        let (s2, _, _) = try await env.post(launch.token, body: gz, headers: ["content-encoding": "gzip"])
        #expect(s2 == 200)
        let g = try #require(env.mock.requests.last)
        #expect(g.header("content-encoding") == nil)
        #expect(String(decoding: g.body, as: UTF8.self).contains("Morph Test Domain"))
    }

    @Test func concurrentRequestsAndEventsStream() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        let launch = try await env.client.createSession(SessionSpec(name: "c", cwd: "/tmp"))
        let events = env.client.eventStream(session: launch.session.id)
        let collector = Task { () -> Int in
            var n = 0
            for try await e in events where e.kind == .exchangeFinished {
                n += 1
                if n == 20 { break }
            }
            return n
        }
        try await Task.sleep(for: .milliseconds(200))
        try await withThrowingTaskGroup(of: Int.self) { g in
            for i in 0..<20 { g.addTask { try await env.post(launch.token, body: sampleBody(results: [("toolu_c\(i)", "r\(i)")])).0 } }
            for try await s in g { #expect(s == 200) }
        }
        #expect(try await collector.value == 20)
        #expect(try await env.client.timeline(launch.session.id).exchanges.count == 20)
    }

    @Test func decisionsSurviveDaemonRestart() async throws {
        let mock = MockUpstream()
        try await mock.start()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("diorama-restart-\(UUID().uuidString)")
        let env1 = try await TestEnv.start(home: home, mock: mock)
        _ = try await env1.client.createProfile(Profile(name: "web", rules: [Rule(name: "r", match: RuleMatch(tools: ["WebFetch"]), instructions: "rename")]))
        let launch = try await env1.client.createSession(SessionSpec(name: "persist", cwd: "/tmp", profile: "web"))
        _ = try await env1.post(launch.token, body: sampleBody())
        let firstForwarded = try #require(mock.requests.last).body
        await env1.stop(keepMock: true)

        // New daemon process state, same data directory; a provider that must not be called.
        let env2 = try await TestEnv.start(provider: ScriptedRewriteProvider { _ in RewriteResponse(status: .failed, error: "must not be called") }, home: home, mock: mock)
        defer { Task { await env2.stop() } }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(env2.port)/s/\(launch.token)/v1/messages")!)
        req.httpMethod = "POST"
        req.httpBody = Data(sampleBody())
        _ = try await URLSession.shared.data(for: req)
        #expect(try #require(mock.requests.last).body == firstForwarded)
    }

    @Test func headAndOtherPathsPassThrough() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        let launch = try await env.client.createSession(SessionSpec(name: "h", cwd: "/tmp"))
        env.mock.setHandler { r in r.method == "HEAD" ? MockUpstream.Response(status: 200, headers: [], chunks: []) : .json(#"{"data":[{"id":"claude-opus-5-5"}]}"#) }
        var head = URLRequest(url: URL(string: "\(launch.baseURL)/api/hello")!)
        head.httpMethod = "HEAD"
        let (_, r1) = try await URLSession.shared.data(for: head)
        #expect((r1 as! HTTPURLResponse).statusCode == 200)
        let (d2, _) = try await URLSession.shared.data(from: URL(string: "\(launch.baseURL)/v1/models?limit=1000")!)
        #expect(String(decoding: d2, as: UTF8.self).contains("claude-opus-5-5"))
        #expect(env.mock.requests.map(\.uri) == ["/api/hello", "/v1/models?limit=1000"])
    }

    @Test func stopReturnsPromptlyWithOpenConnectionsAndEventStreams() async throws {
        let env = try await TestEnv.start()
        let launch = try await env.client.createSession(SessionSpec(name: "stop", cwd: "/tmp"))
        _ = try await env.post(launch.token, body: sampleBody())          // leaves a keep-alive connection open
        let events = env.client.eventStream()                                // long-lived SSE connection
        let reader = Task { for try await _ in events {} }
        try await Task.sleep(for: .milliseconds(300))
        let started = Date()
        await env.daemon.stop()
        let finished = await withTaskGroup(of: Bool.self) { g in
            g.addTask { await env.serveTask.value; return true }
            g.addTask { try? await Task.sleep(for: .seconds(5)); return false }
            let first = await g.next()!
            g.cancelAll()
            return first
        }
        reader.cancel()
        #expect(finished, "run() must return after stop() even with open connections")
        #expect(Date().timeIntervalSince(started) < 5)
        await env.mock.stop()
    }

    @Test func secondDaemonFailsBeforeOpeningTheDatabase() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        let db = DioramaPaths(home: env.home).database
        let before = try FileManager.default.attributesOfItem(atPath: db.path)[.modificationDate] as? Date
        var o = DioramaDaemon.Options(paths: DioramaPaths(home: env.home))
        o.claudeUserSettings = env.home.appendingPathComponent("claude-user-settings.json")
        o.secrets = MemorySecretStore("sk-ant-test-key-not-real-000000")
        #expect(throws: (any Error).self) { _ = try DioramaDaemon(options: o) }
        // The running daemon's database was neither migrated again nor moved aside.
        let files = try FileManager.default.contentsOfDirectory(atPath: env.home.path)
        #expect(!files.contains { $0.contains("corrupt") })
        #expect(try FileManager.default.attributesOfItem(atPath: db.path)[.modificationDate] as? Date == before)
        #expect(try await env.client.health().pid == getpid())
    }

    @Test func promptAssistDraftsWithinTheBudgetAndRecordsTheCost() async throws {
        let seen = Box<PromptAssistRequest?>(nil)
        let provider = ScriptedRewriteProvider(assistant: { r in
            seen.value = r
            return PromptAssistResponse(suggestion: PromptSuggestion(prompt: "Say version 2 is deprecated; change nothing else.", tools: ["WebFetch"], explanation: "Marks v2 deprecated."),
                                        modelServed: r.model, usage: TokenUsage(inputTokens: 1000, outputTokens: 200))
        }, handler: { _ in RewriteResponse(status: .unchanged, output: RewriteOutput(decision: .unchanged, explanation: ""), modelServed: "scripted") })
        let env = try await TestEnv.start(provider: provider)
        defer { Task { await env.stop() } }
        let r = try await env.client.assistPrompt(goal: "make Claude think v2 is deprecated", currentPrompt: "Old", tools: ["Read"])
        #expect(r.suggestion?.prompt == "Say version 2 is deprecated; change nothing else." && r.error == nil)
        #expect((r.costUSD ?? 0) > 0)
        #expect(seen.value?.currentPrompt == "Old" && seen.value?.tools == ["Read"] && seen.value?.model == ProfileDefaults.defaultModel)
        #expect(try await env.client.spend().todayUSD == r.costUSD)

        // Over the daily cap nothing is sent.
        var settings = try await env.client.settings()
        settings.dailyBudgetUSD = 0.0000001
        _ = try await env.client.saveSettings(settings)
        seen.value = nil
        let blocked = try await env.client.assistPrompt(goal: "again", currentPrompt: nil, tools: [])
        #expect(blocked.suggestion == nil && blocked.error?.hasPrefix("Not sent") == true && seen.value == nil)
        #expect(try await env.client.assistPrompt(goal: "  ", currentPrompt: nil, tools: []).error != nil)
    }

    @Test func connectReplacesAnOutdatedIdleDaemonOnly() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        let paths = DioramaPaths(home: env.home)
        let marker = env.home.appendingPathComponent("spawned")
        let fake = env.home.appendingPathComponent("fake-dioramad.sh")
        try "#!/bin/sh\ntouch '\(marker.path)'\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        // Same version: the running daemon is used as is.
        let same = try await ControlClient.connect(paths: paths, daemonExecutable: fake.path, timeout: 1)
        #expect(same.info.port == env.client.info.port)
        #expect(try await env.client.health().isOutdated() == false)

        // Older but busy: kept, and the caller can see it is outdated.
        let launch = try await env.client.createSession(SessionSpec(name: "busy", cwd: "/tmp"))
        let busy = try await ControlClient.connect(paths: paths, daemonExecutable: fake.path, timeout: 1, currentVersion: "99.0.0")
        let h = try await busy.health()
        #expect(h.isOutdated(comparedTo: "99.0.0") && !h.isIdle && h.activeRuns == 0)
        #expect(!FileManager.default.fileExists(atPath: marker.path))

        // Older and idle: stopped and replaced by this build's daemon.
        _ = try await env.client.endSession(launch.session.id)
        await #expect(throws: (any Error).self) {
            _ = try await ControlClient.connect(paths: paths, daemonExecutable: fake.path, timeout: 1, currentVersion: "99.0.0")
        }
        // The fake daemon runs on its own; under load it can take a moment.
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        #expect((try? await env.client.health()) == nil)
    }

    @Test func passThroughAddsLittleLatency() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        _ = try await env.client.createProfile(Profile(name: "web", rules: [Rule(name: "r", match: RuleMatch(tools: ["Bash"]), instructions: "x")]))
        let launch = try await env.client.createSession(SessionSpec(name: "lat", cwd: "/tmp", profile: "web"))
        // Realistic body: ~200 KB system prompt and 40 prior tool results (all replays after the first turn).
        let results = (0..<40).map { (id: "toolu_lat\($0)", text: "result \($0)") }
        let base = String(decoding: sampleBody(results: results), as: UTF8.self)
        let body = Array(base.replacingOccurrences(of: #""max_tokens":1000"#, with: #""max_tokens":1000,"system":"\#(String(repeating: "s", count: 200_000))""#).utf8)
        // Other suites run in parallel and compete for the CPU, so measure up to three rounds and keep
        // the best p95: a real regression misses the budget in every round.
        var best = Double.infinity
        var seen = 1
        for round in 1...3 {
            for _ in 0..<60 { _ = try await env.post(launch.token, body: body) }
            let all = try await env.client.timeline(launch.session.id).exchanges.compactMap(\.addedLatencyMs)
            let added = all.dropFirst(seen).sorted()
            seen = all.count
            let p95 = added[Int(Double(added.count) * 0.95)]
            print("ADDED_LATENCY_MS round=\(round) p50=\(added[added.count / 2]) p95=\(p95) n=\(added.count)")
            best = min(best, p95)
            if best < 25 { break }
        }
        #expect(best < 25, "p95 added latency \(best) ms")
    }

    @Test func controlAPIProfilesSettingsKeyAndDoctor() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        let c = env.client
        let v1 = try await c.createProfile(Profile(name: "p", rules: [Rule(name: "r", match: RuleMatch(tools: ["Bash"]), instructions: "a")]))
        var p = v1.profile
        p.rules[0].instructions = "b"
        let detail = try await c.updateProfile(v1.profileId, p)
        #expect(detail.current.number == 2)
        #expect(detail.versions.count == 2)
        await #expect(throws: ClientError.self) { _ = try await c.createProfile(Profile(name: "bad", rules: [Rule(name: "r", match: RuleMatch(tools: []), instructions: "")])) }
        await #expect(throws: ClientError.self) { _ = try await c.createSession(SessionSpec(name: "x", cwd: "/tmp", profile: "nope")) }
        var s = try await c.settings()
        s.retentionDays = 3
        #expect(try await c.saveSettings(s).retentionDays == 3)
        #expect(try await c.keyStatus().configured)
        #expect(try await c.keyStatus().hint == "…0000")
        await #expect(throws: ClientError.self) { _ = try await c.setKey("short") }
        let report = try await c.doctor()
        #expect(report.checks.contains { $0.name == "Database" && $0.status == .ok })
        #expect(try await c.templates().count >= 3)
    }
}

func gzip(_ bytes: [UInt8]) throws -> [UInt8] {
    let raw = try (Data(bytes) as NSData).compressed(using: .zlib) as Data
    var out: [UInt8] = [0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 0xFF]
    out += raw
    var crc = crc32(bytes)
    var size = UInt32(truncatingIfNeeded: bytes.count)
    out += withUnsafeBytes(of: &crc) { Array($0) }
    out += withUnsafeBytes(of: &size) { Array($0) }
    return out
}

func crc32(_ bytes: [UInt8]) -> UInt32 {
    var c: UInt32 = 0xFFFF_FFFF
    for b in bytes {
        c ^= UInt32(b)
        for _ in 0..<8 { c = (c >> 1) ^ (0xEDB8_8320 & (0 &- (c & 1))) }
    }
    return ~c
}


@Suite struct OllamaProviderTests {
    @Test func rewriteAndJudgeAgainstFakeOllama() async throws {
        let mock = MockUpstream { req in
            guard req.uri == "/api/chat", let body = try? JSONSerialization.jsonObject(with: Data(req.body)) as? [String: Any] else { return .json("{}", status: 404) }
            let isJudge = ((body["messages"] as? [[String: Any]])?.first?["content"] as? String)?.contains("research experiment") == true
            let content = isJudge
                ? #"{"verdict":"adopted","rationale":"repeats it"}"#
                : #"{"decision":"edit","edits":[{"find":"Example","replace":"Local","rationale":"r"}],"content":"","explanation":"local edit"}"#
            let encoded = String(decoding: JSONEncodingHelper.string(content), as: UTF8.self)
            return .json(#"{"model":"\#(body["model"] as? String ?? "")","message":{"role":"assistant","content":\#(encoded)},"prompt_eval_count":120,"eval_count":30,"done":true}"#)
        }
        try await mock.start()
        defer { Task { await mock.stop() } }
        let p = OllamaRewriteProvider(baseURL: { mock.url })
        let r = await p.rewrite(RewriteRequest(toolName: "WebFetch", toolInput: "{}", segments: ["Example page"], instructions: [RuleInstruction(name: "n", text: "t")], taskContext: nil, model: "ollama:llama3.1", effort: nil, maxOutputTokens: 100, timeout: 5))
        #expect(r.status == .succeeded)
        #expect(r.output?.edits.first?.replace == "Local")
        #expect(r.modelServed == "ollama:llama3.1")
        #expect(r.usage?.inputTokens == 120)
        let firstRequest = try #require(mock.requests.first)
        let sent = try #require(try JSONSerialization.jsonObject(with: Data(firstRequest.body)) as? [String: Any])
        #expect(sent["model"] as? String == "llama3.1")
        #expect(sent["stream"] as? Bool == false)
        #expect((sent["format"] as? [String: Any])?["type"] as? String == "object")
        #expect((sent["options"] as? [String: Any])?["num_ctx"] as? Int == 8192, "a context that fits the prompt, not Ollama's small default")
        #expect((sent["options"] as? [String: Any])?["num_predict"] as? Int == 100, "output is capped (the rule's limit here)")
        #expect(Pricing.cost(model: "ollama:llama3.1", usage: TokenUsage(inputTokens: 1000)) == 0)
        let j = await p.judge(JudgeRequest(task: "t", changes: [JudgedChange(before: "a", after: "b")], finalOutput: "b", question: "q", model: "ollama:llama3.1"))
        #expect(j.verdict == "adopted")
        #expect(j.costUSD == 0)
    }

    @Test func sizesTheContextToThePrompt() async {
        #expect(OllamaRewriteProvider.contextSize(promptChars: 3000, maxOutput: 1024) == 8192)
        #expect(OllamaRewriteProvider.contextSize(promptChars: 60_000, maxOutput: 4096) == 26624)
        #expect(OllamaRewriteProvider.contextSize(promptChars: 200_000, maxOutput: 4096) == nil)
        let p = OllamaRewriteProvider(baseURL: { URL(string: "http://127.0.0.1:9")! })
        let r = await p.rewrite(RewriteRequest(toolName: "t", toolInput: "{}", segments: [String(repeating: "x", count: 250_000)], instructions: [], taskContext: nil,
                                               model: "ollama:m", effort: nil, maxOutputTokens: 1000, timeout: 3))
        #expect(r.status == .failed && r.error?.contains("too long for a local model") == true, "fails clearly instead of being cut off")
    }

    @Test func reportsWhenOllamaIsNotRunning() async {
        let p = OllamaRewriteProvider(baseURL: { URL(string: "http://127.0.0.1:9")! })
        let r = await p.rewrite(RewriteRequest(toolName: "t", toolInput: "{}", segments: ["x"], instructions: [], taskContext: nil, model: "ollama:m", effort: nil, maxOutputTokens: 10, timeout: 3))
        #expect(r.status == .failed)
        #expect(r.error?.contains("not running") == true)
    }
}


@Suite struct UpdateCheckerTests {
    @Test func semverComparison() {
        #expect(UpdateChecker.compare("1.1.0", "1.0.9") > 0)
        #expect(UpdateChecker.compare("1.0.0", "1.0.0") == 0)
        #expect(UpdateChecker.compare("1.0.0-beta.1", "1.0.0") < 0)
        #expect(UpdateChecker.compare("1.10.0", "1.9.0") > 0)
        #expect(UpdateChecker.compare("2.0", "1.99.99") > 0)
    }
}

/// A mutable value a test's @Sendable closure can write.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
