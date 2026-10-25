import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

/// A buffered HTTP request (bodies are needed in full before rewriting).
struct HTTPRequest: Sendable {
    let method: String
    let uri: String
    let path: String
    let query: [String: String]
    let headers: [(String, String)]
    let body: [UInt8]
    let receivedAt: Date

    func header(_ name: String) -> String? {
        let n = name.lowercased()
        return headers.first { $0.0.lowercased() == n }?.1
    }
}

/// Streams a response back to the client.
struct ResponseWriter: Sendable {
    let outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>
    let allocator: ByteBufferAllocator
    let isHead: Bool

    func head(_ status: Int, _ headers: [(String, String)]) async throws {
        var h = HTTPHeaders()
        for (k, v) in headers { h.add(name: k, value: v) }
        try await outbound.write(.head(HTTPResponseHead(version: .http1_1, status: .init(statusCode: status), headers: h)))
    }

    func body(_ bytes: some Collection<UInt8>) async throws {
        guard !isHead, !bytes.isEmpty else { return }
        var buf = allocator.buffer(capacity: bytes.count)
        buf.writeBytes(bytes)
        try await outbound.write(.body(.byteBuffer(buf)))
    }

    func end() async throws { try await outbound.write(.end(nil)) }

    /// Convenience: complete response with a fixed body.
    func send(_ status: Int, _ headers: [(String, String)], _ body: [UInt8]) async throws {
        var h = headers
        h.append(("content-length", String(isHead ? 0 : body.count)))
        try await head(status, h)
        try await self.body(body)
        try await end()
    }
}

protocol HTTPHandler: Sendable {
    func handle(_ request: HTTPRequest, _ writer: ResponseWriter) async
}

/// Minimal async HTTP/1.1 server on SwiftNIO (keep-alive, pipelining via NIO's handler).
final class HTTPServer: @unchecked Sendable {
    let group: MultiThreadedEventLoopGroup
    let maxBodyBytes: Int
    private var channel: NIOAsyncChannel<NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>, Never>?
    private(set) var port: Int = 0
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: Channel] = [:]
    private var serving = false

    init(threads: Int = System.coreCount, maxBodyBytes: Int) {
        group = MultiThreadedEventLoopGroup(numberOfThreads: max(2, min(threads, 8)))
        self.maxBodyBytes = maxBodyBytes
    }

    /// Binds to 127.0.0.1. `port` 0 picks a free port; otherwise tries `port`, then `port+1…+20`.
    func bind(port requested: Int, exactPort: Bool = false) async throws -> Int {
        var lastError: Error?
        let candidates = requested == 0 ? [0] : (exactPort ? [requested] : Array(requested...(requested + 20)))
        for p in candidates {
            do {
                let ch = try await ServerBootstrap(group: group)
                    .serverChannelOption(ChannelOptions.backlog, value: 256)
                    .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                    .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
                    .bind(host: "127.0.0.1", port: p) { child in
                        child.eventLoop.makeCompletedFuture {
                            try child.pipeline.syncOperations.configureHTTPServerPipeline(withErrorHandling: true)
                            return try NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>(wrappingChannelSynchronously: child)
                        }
                    }
                channel = ch
                port = ch.channel.localAddress?.port ?? p
                return port
            } catch {
                lastError = error
            }
        }
        throw lastError ?? ChannelError.ioOnClosedChannel
    }

    func serve(_ handler: HTTPHandler) async throws {
        guard let channel else { return }
        lock.withLock { serving = true }
        defer { lock.withLock { serving = false } }
        try await channel.executeThenClose { inbound in
            try await withThrowingDiscardingTaskGroup { group in
                for try await connection in inbound {
                    group.addTask {
                        await self.handleConnection(connection, handler)
                    }
                }
            }
        }
    }

    private func handleConnection(_ connection: NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>, _ handler: HTTPHandler) async {
        let allocator = connection.channel.allocator
        let key = ObjectIdentifier(connection.channel)
        lock.withLock { connections[key] = connection.channel }
        defer { lock.withLock { _ = connections.removeValue(forKey: key) } }
        do {
            try await connection.executeThenClose { inbound, outbound in
                var head: HTTPRequestHead?
                var body: [UInt8] = []
                var tooLarge = false
                for try await part in inbound {
                    switch part {
                    case .head(let h):
                        head = h
                        body = []
                        tooLarge = false
                    case .body(let b):
                        if body.count + b.readableBytes > maxBodyBytes {
                            tooLarge = true
                        } else if !tooLarge {
                            body.append(contentsOf: b.readableBytesView)
                        }
                    case .end:
                        guard let h = head else { continue }
                        head = nil
                        let writer = ResponseWriter(outbound: outbound, allocator: allocator, isHead: h.method == .HEAD)
                        if tooLarge {
                            let msg = Array(#"{"type":"error","error":{"type":"request_too_large","message":"Request body exceeds Diorama's limit"}}"#.utf8)
                            try await writer.send(413, [("content-type", "application/json"), ("x-should-retry", "false"), ("connection", "close")], msg)
                            return
                        }
                        let (path, query) = Self.split(h.uri)
                        let req = HTTPRequest(
                            method: h.method.rawValue, uri: h.uri, path: path, query: query,
                            headers: h.headers.map { ($0.name, $0.value) }, body: body, receivedAt: Date())
                        body = []
                        await handler.handle(req, writer)
                        if !h.isKeepAlive { return }
                    }
                }
            }
        } catch {
            // Client went away or protocol error; the connection is closed either way.
        }
    }

    /// Stops accepting, closes every open client connection (keep-alive and event streams),
    /// waits for the serve loop to finish, and only then shuts the event loops down. Shutting
    /// the loops down first would leave connection tasks waiting forever.
    func shutdown() async {
        try? await channel?.channel.close()
        let open = lock.withLock { Array(connections.values) }
        for ch in open { ch.close(promise: nil) }
        let deadline = Date().addingTimeInterval(5)
        while lock.withLock({ serving }), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        try? await group.shutdownGracefully()
    }

    static func split(_ uri: String) -> (String, [String: String]) {
        guard let q = uri.firstIndex(of: "?") else { return (uri, [:]) }
        let path = String(uri[..<q])
        var out: [String: String] = [:]
        for pair in uri[uri.index(after: q)...].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            let k = String(kv[0]).removingPercentEncoding ?? String(kv[0])
            let v = kv.count > 1 ? (String(kv[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(kv[1])) : ""
            out[k] = v
        }
        return (path, out)
    }
}
