import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

/// A scriptable fake Anthropic API used by integration and contract tests.
public final class MockUpstream: @unchecked Sendable {
    public struct Request: Sendable {
        public let method: String
        public let uri: String
        public let headers: [(String, String)]
        public let body: [UInt8]
        public func header(_ n: String) -> String? { headers.first { $0.0.lowercased() == n.lowercased() }?.1 }
    }

    public struct Response: Sendable {
        public var status: Int = 200
        public var headers: [(String, String)] = [("content-type", "application/json")]
        public var chunks: [(bytes: [UInt8], delay: Duration)] = []

        public init(status: Int = 200, headers: [(String, String)] = [("content-type", "application/json")], chunks: [(bytes: [UInt8], delay: Duration)] = []) {
            self.status = status
            self.headers = headers
            self.chunks = chunks
        }

        public static func json(_ s: String, status: Int = 200, headers: [(String, String)] = []) -> Response {
            Response(status: status, headers: [("content-type", "application/json")] + headers, chunks: [(Array(s.utf8), .zero)])
        }

        public static func sse(_ events: [String], delay: Duration = .zero) -> Response {
            Response(status: 200, headers: [("content-type", "text/event-stream"), ("cache-control", "no-cache"), ("request-id", "req_mock")],
                     chunks: events.map { (Array($0.utf8), delay) })
        }
    }

    let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    private var channel: NIOAsyncChannel<NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>, Never>?
    private let lock = NSLock()
    private var _requests: [Request] = []
    private var handler: @Sendable (Request) async -> Response
    private var serveTask: Task<Void, Never>?
    public private(set) var port = 0

    public init(handler: @escaping @Sendable (Request) async -> Response = { _ in MockUpstream.defaultMessage() }) {
        self.handler = handler
    }

    public var requests: [Request] { lock.withLock { _requests } }
    public func setHandler(_ h: @escaping @Sendable (Request) async -> Response) { lock.withLock { handler = h } }
    public var url: URL { URL(string: "http://127.0.0.1:\(port)")! }

    public func start() async throws {
        let ch = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: 0) { child in
                child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.configureHTTPServerPipeline()
                    return try NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>(wrappingChannelSynchronously: child)
                }
            }
        channel = ch
        port = ch.channel.localAddress!.port!
        serveTask = Task {
            try? await ch.executeThenClose { inbound in
                await withDiscardingTaskGroup { group in
                    do {
                        for try await conn in inbound {
                            group.addTask { await self.serve(conn) }
                        }
                    } catch {}
                }
            }
        }
    }

    private func serve(_ conn: NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>) async {
        try? await conn.executeThenClose { inbound, outbound in
            var head: HTTPRequestHead?
            var body: [UInt8] = []
            for try await part in inbound {
                switch part {
                case .head(let h):
                    head = h
                    body = []
                case .body(let b): body.append(contentsOf: b.readableBytesView)
                case .end:
                    guard let h = head else { continue }
                    let req = Request(method: h.method.rawValue, uri: h.uri, headers: h.headers.map { ($0.name, $0.value) }, body: body)
                    let handler = lock.withLock {
                        _requests.append(req)
                        return self.handler
                    }
                    let resp = await handler(req)
                    var headers = HTTPHeaders()
                    for (k, v) in resp.headers { headers.add(name: k, value: v) }
                    try await outbound.write(.head(HTTPResponseHead(version: .http1_1, status: .init(statusCode: resp.status), headers: headers)))
                    for c in resp.chunks {
                        if c.delay != .zero { try await Task.sleep(for: c.delay) }
                        var buf = conn.channel.allocator.buffer(capacity: c.bytes.count)
                        buf.writeBytes(c.bytes)
                        try await outbound.write(.body(.byteBuffer(buf)))
                    }
                    try await outbound.write(.end(nil))
                }
            }
        }
    }

    public func stop() async {
        try? await channel?.channel.close()
        serveTask?.cancel()
        try? await group.shutdownGracefully()
    }

    // MARK: Canned responses

    public static func sseEvents(text: String = "Hello", toolUse: (id: String, name: String, input: String)? = nil, usage: (Int, Int, Int, Int) = (10, 5, 100, 20)) -> [String] {
        var events = [
            #"event: message_start\#ndata: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","model":"claude-opus-5-5","content":[],"stop_reason":null,"usage":{"input_tokens":\#(usage.0),"output_tokens":1,"cache_read_input_tokens":\#(usage.2),"cache_creation_input_tokens":\#(usage.3)}}}\#n\#n"#,
            "event: ping\ndata: {\"type\":\"ping\"}\n\n",
        ]
        var stop = "end_turn"
        if let t = toolUse {
            stop = "tool_use"
            events.append(#"event: content_block_start\#ndata: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"\#(t.id)","name":"\#(t.name)","input":{}}}\#n\#n"#)
            let partial = String(decoding: JSONEncodingHelper.string(t.input), as: UTF8.self)
            events.append(#"event: content_block_delta\#ndata: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":\#(partial)}}\#n\#n"#)
        } else {
            events.append(#"event: content_block_start\#ndata: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\#n\#n"#)
            let t = String(decoding: JSONEncodingHelper.string(text), as: UTF8.self)
            events.append(#"event: content_block_delta\#ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":\#(t)}}\#n\#n"#)
        }
        events.append("event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n")
        events.append(#"event: message_delta\#ndata: {"type":"message_delta","delta":{"stop_reason":"\#(stop)","stop_sequence":null},"usage":{"output_tokens":\#(usage.1)}}\#n\#n"#)
        events.append("event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n")
        return events
    }

    public static func defaultMessage() -> Response { .sse(sseEvents()) }
}

public enum JSONEncodingHelper {
    public static func string(_ s: String) -> [UInt8] {
        (try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])).map { Array($0.dropFirst().dropLast()) } ?? []
    }
}
