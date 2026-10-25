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
                      home: URL? = nil, mock: MockUpstream? = nil) async throws -> TestEnv {
        let home = home ?? FileManager.default.temporaryDirectory.appendingPathComponent("diorama-gw-\(UUID().uuidString)")
        let mock = mock ?? MockUpstream()
        if mock.port == 0 { try await mock.start() }
        var o = DioramaDaemon.Options(paths: DioramaPaths(home: home))
        o.port = 0
        o.upstream = mock.url
        o.providerOverride = provider
        o.secrets = MemorySecretStore("sk-ant-test-key-not-real-000000")
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
func rawHTTP(port: Int, _ request: String) throws -> String {
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
        let badHost = try rawHTTP(port: env.port, "GET /s/\(launch.token)/v1/models HTTP/1.1\r\nHost: evil.example:80\r\nConnection: close\r\n\r\n")
        #expect(badHost.hasPrefix("HTTP/1.1 403"))
        let origin = try rawHTTP(port: env.port, "GET /api/v1/health HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: https://evil.example\r\nAuthorization: Bearer \(env.client.info.controlToken)\r\nConnection: close\r\n\r\n")
        #expect(origin.hasPrefix("HTTP/1.1 403"))
        let noAuth = try rawHTTP(port: env.port, "GET /api/v1/health HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
        #expect(noAuth.hasPrefix("HTTP/1.1 401"))
        let ok = try rawHTTP(port: env.port, "GET /api/v1/health HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer \(env.client.info.controlToken)\r\nConnection: close\r\n\r\n")
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

    @Test func passThroughAddsLittleLatency() async throws {
        let env = try await TestEnv.start()
        defer { Task { await env.stop() } }
        _ = try await env.client.createProfile(Profile(name: "web", rules: [Rule(name: "r", match: RuleMatch(tools: ["Bash"]), instructions: "x")]))
        let launch = try await env.client.createSession(SessionSpec(name: "lat", cwd: "/tmp", profile: "web"))
        // Realistic body: ~200 KB system prompt and 40 prior tool results (all replays after the first turn).
        let results = (0..<40).map { (id: "toolu_lat\($0)", text: "result \($0)") }
        let base = String(decoding: sampleBody(results: results), as: UTF8.self)
        let body = Array(base.replacingOccurrences(of: #""max_tokens":1000"#, with: #""max_tokens":1000,"system":"\#(String(repeating: "s", count: 200_000))""#).utf8)
        for _ in 0..<60 { _ = try await env.post(launch.token, body: body) }
        let added = try await env.client.timeline(launch.session.id).exchanges.dropFirst().compactMap(\.addedLatencyMs).sorted()
        let p95 = added[Int(Double(added.count) * 0.95)]
        print("ADDED_LATENCY_MS p50=\(added[added.count / 2]) p95=\(p95) n=\(added.count)")
        #expect(p95 < 25, "p95 added latency \(p95) ms")
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
