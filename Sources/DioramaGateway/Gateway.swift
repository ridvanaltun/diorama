import DioramaCore
import DioramaEngine
import DioramaStore
import Foundation

/// Fan-out of live events to control-API subscribers (timeline refresh, run progress).
final class EventHub: @unchecked Sendable {
    private let lock = NSLock()
    private var subscribers: [UUID: AsyncStream<SessionEvent>.Continuation] = [:]

    func subscribe() -> (UUID, AsyncStream<SessionEvent>) {
        let id = UUID()
        let (stream, cont) = AsyncStream<SessionEvent>.makeStream(bufferingPolicy: .bufferingNewest(1000))
        lock.withLock { subscribers[id] = cont }
        cont.onTermination = { [weak self] _ in self?.unsubscribe(id) }
        return (id, stream)
    }

    func unsubscribe(_ id: UUID) {
        let c = lock.withLock { subscribers.removeValue(forKey: id) }
        c?.finish()
    }

    func publish(_ event: SessionEvent) {
        let subs = lock.withLock { Array(subscribers.values) }
        for s in subs { s.yield(event) }
    }

    func finishAll() {
        let subs = lock.withLock { () -> [AsyncStream<SessionEvent>.Continuation] in
            let s = Array(subscribers.values)
            subscribers.removeAll()
            return s
        }
        for s in subs { s.finish() }
    }
}

/// Handles `/s/{token}/…` — the Anthropic Messages API gateway for routed sessions.
struct GatewayHandler: Sendable {
    let store: Store
    let engine: DecisionEngine
    let upstream: UpstreamClient
    let upstreamBase: URL
    let hub: EventHub
    let sessions: SessionCache

    static func anthropicError(_ type: String, _ message: String) -> [UInt8] {
        Array(#"{"type":"error","error":{"type":"\#(type)","message":\#(String(decoding: DioramaJSONString(message), as: UTF8.self))}}"#.utf8)
    }

    func reject(_ writer: ResponseWriter, _ status: Int, _ type: String, _ message: String, retry: Bool = false) async {
        try? await writer.send(
            status, [("content-type", "application/json"), ("x-should-retry", retry ? "true" : "false")],
            GatewayHandler.anthropicError(type, message))
    }

    func handle(token: String, rest: String, _ req: HTTPRequest, _ writer: ResponseWriter) async {
        guard let session = sessions.lookup(token: token) else {
            await reject(writer, 403, "permission_error", "Unknown or expired Diorama session. Start Claude Code with `diorama run`.")
            return
        }
        let requestClass = req.header("x-claude-code-request-class")
        let claudeSessionId = req.header("x-claude-code-session-id")
        if let csid = claudeSessionId { sessions.noteClaudeSession(sessionId: session.id, claudeSessionId: csid) }
        let path = rest.isEmpty ? "/" : rest
        let pathOnly = HTTPServer.split(path).0
        let exchangeId: Int64
        do {
            exchangeId = try store.beginExchange(Store.NewExchange(
                sessionId: session.id, method: req.method, path: pathOnly, requestClass: requestClass,
                agentId: req.header("x-claude-code-agent-id"), claudeSessionId: claudeSessionId,
                requestHeaders: Self.redact(req.headers)))
        } catch {
            await reject(writer, 503, "api_error", "Diorama could not record the request: \(error)", retry: true)
            return
        }
        hub.publish(SessionEvent(id: 0, sessionId: session.id, kind: .exchangeStarted, message: "\(req.method) \(pathOnly)", refId: String(exchangeId), createdAt: Date()))

        var forwardHeaders = req.headers.filter { !HopByHop.request.contains($0.0.lowercased()) }
        var forwardBody = req.body
        var entries: [ToolResultEntry] = []
        var model: String?
        let settings = sessions.settings()
        let isMessages = req.method == "POST" && (pathOnly == "/v1/messages" || pathOnly == "/v1/messages/count_tokens")
        if isMessages, !req.body.isEmpty {
            let encoding = req.header("content-encoding")?.lowercased()
            var decoded: [UInt8]? = req.body
            if let encoding, encoding != "identity" {
                decoded = encoding == "gzip" ? Gzip.decode(req.body) : nil
                if decoded == nil {
                    store.addEvent(sessionId: session.id, kind: .anomaly, message: "Request used unsupported content-encoding '\(encoding)'; forwarded without inspection", refId: String(exchangeId))
                }
            }
            if let decoded {
                let result = await engine.process(body: decoded, session: session, exchangeId: exchangeId, requestClass: requestClass)
                entries = result.entries
                model = result.model
                if let out = result.forwardedBody {
                    forwardBody = out
                    forwardHeaders.removeAll { $0.0.lowercased() == "content-encoding" }
                } else if decoded != req.body {
                    // Unchanged: forward the client's original (still encoded) bytes.
                    forwardBody = req.body
                }
            }
        }
        let modified = forwardBody != req.body
        var requestBlob: String?, forwardedBlob: String?
        if settings.captureRawBodies, !req.body.isEmpty {
            requestBlob = try? store.blobs.put(req.body)
            if modified { forwardedBlob = try? store.blobs.put(forwardBody) }
        }
        let added = Date().timeIntervalSince(req.receivedAt) * 1000
        try? store.recordRequest(exchangeId: exchangeId, .init(model: model, toolResults: entries, requestBlob: requestBlob, forwardedBlob: forwardedBlob, addedLatencyMs: added))

        // Forward upstream.
        var urlRequest = URLRequest(url: URL(string: upstreamBase.absoluteString.trimmingSuffix("/") + path)!)
        urlRequest.httpMethod = req.method
        for (k, v) in forwardHeaders { urlRequest.addValue(v, forHTTPHeaderField: k) }
        urlRequest.setValue("identity", forHTTPHeaderField: "accept-encoding")
        if !forwardBody.isEmpty || req.method == "POST" || req.method == "PUT" { urlRequest.httpBody = Data(forwardBody) }

        let started = Date()
        let response: UpstreamClient.Response
        do {
            response = try await upstream.send(urlRequest)
        } catch {
            let msg = "Diorama could not reach the upstream API: \(error.localizedDescription)"
            try? store.recordResponse(exchangeId: exchangeId, .init(status: 502, ttfbMs: nil, durationMs: Date().timeIntervalSince(started) * 1000, usage: nil, assistant: nil, error: msg, responseBlob: nil, responseHeaders: [:]))
            await reject(writer, 502, "api_error", msg, retry: true)
            return
        }
        let ttfb = Date().timeIntervalSince(started) * 1000
        let outHeaders = response.headers.filter { !HopByHop.response.contains($0.0) }
        var observer = ResponseObserver(contentType: response.headers.first { $0.0 == "content-type" }?.1)
        var clientGone = false
        var streamError: String?
        var headSent = false
        do {
            try await writer.head(response.status, outHeaders)
            headSent = true
            for try await chunk in response.body {
                observer.feed(chunk)
                do {
                    try await writer.body(chunk)
                } catch {
                    clientGone = true
                    response.cancel()
                    break
                }
            }
        } catch {
            streamError = headSent ? "upstream stream ended with error: \(error.localizedDescription)" : "could not write response: \(error.localizedDescription)"
            response.cancel()
        }
        observer.finish()
        // Record before ending the response so a client that reads the timeline right after the
        // stream completes always sees this exchange.
        let responseBlob = settings.captureRawBodies && !observer.captured.isEmpty ? try? store.blobs.put(observer.captured) : nil
        var errorText = observer.errorMessage ?? streamError
        if clientGone { errorText = (errorText.map { $0 + "; " } ?? "") + "client disconnected" }
        try? store.recordResponse(exchangeId: exchangeId, .init(
            status: response.status, ttfbMs: ttfb, durationMs: Date().timeIntervalSince(started) * 1000, usage: observer.usage,
            assistant: observer.assistant, error: errorText, responseBlob: responseBlob,
            responseHeaders: Dictionary(Self.redact(response.headers).map { ($0.key, $0.value) }, uniquingKeysWith: { a, _ in a })))
        // Remember WebFetch calls so pre-extraction rules can tie the page to its URL. Done
        // before ending the response: Claude Code runs the tool only after the response ends.
        if let uses = observer.assistant?.toolUses, !uses.isEmpty {
            await engine.noteToolUses(sessionId: session.id, toolUses: uses)
        }
        if !clientGone { try? await writer.end() }
        hub.publish(SessionEvent(id: 0, sessionId: session.id, kind: .exchangeFinished, message: "\(response.status) \(pathOnly)", refId: String(exchangeId), createdAt: Date()))
    }

    static func redact(_ headers: [(String, String)]) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in headers {
            let key = k.lowercased()
            out[key] = HopByHop.redacted.contains(key) ? "<redacted>" : v
        }
        return out
    }
}

/// Token → session lookup with a small in-memory cache.
final class SessionCache: @unchecked Sendable {
    private let store: Store
    private let lock = NSLock()
    private var byHash: [String: SessionRecord] = [:]
    private var knownClaudeIds = Set<String>()
    private var cachedSettings: DioramaSettings
    private var settingsLoadedAt = Date()

    init(store: Store) {
        self.store = store
        cachedSettings = store.settings()
    }

    func lookup(token: String) -> SessionRecord? {
        guard token.count == 32, token.allSatisfy(\.isHexDigit) else { return nil }
        let hash = Hashing.sha256Hex(token)
        if let s = lock.withLock({ byHash[hash] }) { return s }
        guard let s = try? store.session(tokenHash: hash) else { return nil }
        lock.withLock { byHash[hash] = s }
        return s
    }

    func invalidate() { lock.withLock { byHash.removeAll() } }

    func noteClaudeSession(sessionId: String, claudeSessionId: String) {
        let key = sessionId + "|" + claudeSessionId
        let isNew = lock.withLock { knownClaudeIds.insert(key).inserted }
        if isNew { try? store.recordClaudeSessionId(sessionId: sessionId, claudeSessionId: claudeSessionId) }
    }

    func settings() -> DioramaSettings {
        lock.withLock {
            if Date().timeIntervalSince(settingsLoadedAt) > 5 {
                cachedSettings = store.settings()
                settingsLoadedAt = Date()
            }
            return cachedSettings
        }
    }

    func settingsChanged() {
        lock.withLock { settingsLoadedAt = .distantPast }
    }
}

func DioramaJSONString(_ s: String) -> [UInt8] {
    var out: [UInt8] = [0x22]
    for b in s.utf8 {
        switch b {
        case 0x22: out += [0x5C, 0x22]
        case 0x5C: out += [0x5C, 0x5C]
        case 0..<0x20: out += Array(String(format: "\\u%04x", b).utf8)
        default: out.append(b)
        }
    }
    out.append(0x22)
    return out
}

extension String {
    func trimmingSuffix(_ s: String) -> String { hasSuffix(s) ? String(dropLast(s.count)) : self }
}

/// Minimal gzip (RFC 1952) decoder on top of Foundation's raw-DEFLATE support.
enum Gzip {
    static func decode(_ bytes: [UInt8]) -> [UInt8]? {
        guard bytes.count >= 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var i = 10
        if flags & 0x04 != 0 {
            guard i + 2 <= bytes.count else { return nil }
            i += 2 + Int(bytes[i]) | (Int(bytes[i + 1]) << 8)
        }
        if flags & 0x08 != 0 { while i < bytes.count, bytes[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x10 != 0 { while i < bytes.count, bytes[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x02 != 0 { i += 2 }
        guard i < bytes.count - 8 else { return nil }
        let deflate = Data(bytes[i..<(bytes.count - 8)])
        guard let out = try? (deflate as NSData).decompressed(using: .zlib) as Data else { return nil }
        return Array(out)
    }
}
