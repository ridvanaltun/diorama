import Foundation

/// Streams HTTP responses from the upstream API with URLSession, delivering body chunks as
/// they arrive (no buffering), without following redirects, caching or cookies.
final class UpstreamClient: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Response: Sendable {
        let status: Int
        let headers: [(String, String)]
        let body: AsyncThrowingStream<Data, Error>
        let cancel: @Sendable () -> Void
    }

    private struct State {
        var responseContinuation: CheckedContinuation<Response, Error>?
        var bodyContinuation: AsyncThrowingStream<Data, Error>.Continuation
        var body: AsyncThrowingStream<Data, Error>
    }

    private let lock = NSLock()
    private var states: [Int: State] = [:]
    private var session: URLSession!

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Idle timeout between packets: long thinking pauses are bridged by SSE pings, and
        // Claude Code runs its own watchdogs, so this only guards against dead connections.
        cfg.timeoutIntervalForRequest = 600
        cfg.timeoutIntervalForResource = 24 * 3600
        cfg.httpMaximumConnectionsPerHost = 32
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: queue)
    }

    func invalidate() { session.invalidateAndCancel() }

    func send(_ request: URLRequest) async throws -> Response {
        let task = session.dataTask(with: request)
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .unbounded)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Response, Error>) in
                lock.withLock {
                    states[task.taskIdentifier] = State(responseContinuation: cont, bodyContinuation: continuation, body: stream)
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let http = response as? HTTPURLResponse
        var headers: [(String, String)] = []
        for (k, v) in http?.allHeaderFields ?? [:] {
            if let k = k as? String, let v = v as? String { headers.append((k.lowercased(), v)) }
        }
        let cont: CheckedContinuation<Response, Error>?
        let body: AsyncThrowingStream<Data, Error>?
        (cont, body) = lock.withLock {
            let c = states[dataTask.taskIdentifier]?.responseContinuation
            states[dataTask.taskIdentifier]?.responseContinuation = nil
            return (c, states[dataTask.taskIdentifier]?.body)
        }
        completionHandler(.allow)
        if let cont, let body {
            cont.resume(returning: Response(status: http?.statusCode ?? 502, headers: headers, body: body, cancel: { dataTask.cancel() }))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let c = lock.withLock { states[dataTask.taskIdentifier]?.bodyContinuation }
        c?.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let state = lock.withLock { states.removeValue(forKey: task.taskIdentifier) }
        guard let state else { return }
        if let rc = state.responseContinuation {
            rc.resume(throwing: error ?? URLError(.badServerResponse))
        }
        if let error {
            state.bodyContinuation.finish(throwing: error)
        } else {
            state.bodyContinuation.finish()
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

enum HopByHop {
    /// Request headers never forwarded upstream (hop-by-hop, or recomputed by URLSession).
    static let request: Set<String> = [
        "host", "connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade", "te", "trailer",
        "content-length", "accept-encoding", "expect", "proxy-authorization",
    ]
    /// Response headers never forwarded to the client. The body we relay is always decoded and
    /// re-framed by our HTTP/1.1 encoder, so length/encoding headers would be wrong.
    static let response: Set<String> = [
        "connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade", "trailer", "content-length",
        "content-encoding",
    ]
    /// Header values never written to disk.
    static let redacted: Set<String> = ["authorization", "x-api-key", "cookie", "set-cookie", "proxy-authorization"]
}
