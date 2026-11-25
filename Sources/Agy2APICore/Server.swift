import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOHTTP1

/// HTTP front:
///   POST /v1/messages, /v1/messages/count_tokens   Anthropic (Claude Code)
///   POST /v1/chat/completions                       OpenAI Chat Completions
///   POST /v1/responses                              OpenAI Responses (Codex)
///   GET  /v1/models                                 OpenAI or Anthropic list
///   GET  /healthz
/// Paths are also served without the `/v1` prefix.
public final class Agy2APIServer: Sendable {
    public let service: Agy2APIService
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    private let channel = NIOLockedValueBox<Channel?>(nil)
    static let maxBody = 64 * 1024 * 1024

    public init(config: ServiceConfig) {
        service = Agy2APIService(config: config)
    }

    @discardableResult
    public func start() async throws -> Int {
        try await service.start()
        let service = service
        let config = service.config
        let bound = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { child in
                child.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    child.pipeline.addHandler(HTTPHandler(service: service))
                }
            }
            .bind(host: config.host, port: config.port)
            .get()
        channel.withLockedValue { $0 = bound }
        return bound.localAddress?.port ?? config.port
    }

    public func wait() async throws {
        guard let bound = channel.withLockedValue({ $0 }) else { return }
        try await bound.closeFuture.get()
    }

    public func stop() async {
        let bound = channel.withLockedValue { c -> Channel? in defer { c = nil }; return c }
        try? await bound?.close()
        await service.stop()
        try? await group.shutdownGracefully()
    }
}

final class HTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let service: Agy2APIService
    private var head: HTTPRequestHead?
    private var body = ByteBuffer()
    private var tooLarge = false
    private var work: Task<Void, Never>?

    init(service: Agy2APIService) { self.service = service }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h):
            head = h; body.clear(); tooLarge = false
        case .body(var chunk):
            if body.readableBytes + chunk.readableBytes > Agy2APIServer.maxBody { tooLarge = true } else { body.writeBuffer(&chunk) }
        case .end:
            guard let head else { return }
            self.head = nil
            let bytes = Data(body.readBytes(length: body.readableBytes) ?? [])
            body.clear()
            let channel = context.channel
            if tooLarge {
                return Self.json(channel, 413, APIError(status: 413, type: "request_too_large", message: "request body too large").body(for: .chat), keepAlive: false)
            }
            let service = service
            work = Task { await Self.route(service, head, bytes, channel) }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        work?.cancel()
        work = nil
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    // MARK: - Routing

    static func apiKey(_ headers: HTTPHeaders) -> String? {
        if let auth = headers["authorization"].first {
            let t = auth.trimmingCharacters(in: .whitespaces)
            return t.lowercased().hasPrefix("bearer ") ? String(t.dropFirst(7)).trimmingCharacters(in: .whitespaces) : t
        }
        return headers["x-api-key"].first ?? headers["api-key"].first
    }

    private static func route(_ service: Agy2APIService, _ head: HTTPRequestHead, _ body: Data, _ channel: Channel) async {
        var path = head.uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? head.uri
        if path.hasPrefix("/v1/") { path = String(path.dropFirst(3)) }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        let keepAlive = head.isKeepAlive
        let key = apiKey(head.headers)
        let anthropicClient = head.headers["anthropic-version"].first != nil || head.headers["x-api-key"].first != nil

        switch (head.method, path) {
        case (.GET, "/healthz"):
            json(channel, 200, ["ok": true, "version": .string(Agy2APIVersion.current)], keepAlive: keepAlive)
        case (.GET, "/models"):
            do {
                _ = try service.authorize(key)
                let models = try await service.models()
                let created = Int(Date().timeIntervalSince1970)
                if anthropicClient {
                    let data: [JSONValue] = models.map { ["type": "model", "id": .string("agy/" + $0.id), "display_name": .string($0.name),
                                                          "created_at": "2026-01-01T00:00:00Z"] }
                    json(channel, 200, ["data": .array(data), "has_more": false,
                                        "first_id": data.first?["id"] ?? .null, "last_id": data.last?["id"] ?? .null], keepAlive: keepAlive)
                } else {
                    let data: [JSONValue] = models.map { ["id": .string($0.id), "object": "model", "created": .int(created), "owned_by": "agy"] }
                    json(channel, 200, ["object": "list", "data": .array(data)], keepAlive: keepAlive)
                }
            } catch {
                let e = AccountRuntime.apiError(error)
                json(channel, e.status, e.body(for: anthropicClient ? .anthropic : .chat), keepAlive: keepAlive)
            }
        case (.POST, "/messages/count_tokens"):
            do {
                _ = try service.authorize(key)
                json(channel, 200, try AnthropicWire.countTokens(body), keepAlive: keepAlive)
            } catch {
                let e = AccountRuntime.apiError(error)
                json(channel, e.status, e.body(for: .anthropic), keepAlive: keepAlive)
            }
        case (.POST, "/messages"):
            await respond(service, .anthropic, body, key, channel, keepAlive)
        case (.POST, "/chat/completions"):
            await respond(service, .chat, body, key, channel, keepAlive)
        case (.POST, "/responses"):
            await respond(service, .responses, body, key, channel, keepAlive)
        default:
            let e = APIError(status: 404, type: "not_found_error", message: "no route for \(head.method) \(head.uri)")
            json(channel, 404, e.body(for: anthropicClient ? .anthropic : .chat), keepAlive: keepAlive)
        }
    }

    /// `AGY2API_DUMP=<dir>`: keep every request body, for debugging clients.
    static let dumpDirectory = ProcessInfo.processInfo.environment["AGY2API_DUMP"].flatMap { $0.isEmpty ? nil : $0 }

    private static func respond(_ service: Agy2APIService, _ wire: Wire, _ body: Data, _ key: String?, _ channel: Channel, _ keepAlive: Bool) async {
        if let dir = dumpDirectory {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(wire.rawValue).json"
            FileManager.default.createFile(atPath: (dir as NSString).appendingPathComponent(name), contents: body,
                                           attributes: [.posixPermissions: 0o600])
        }
        let request: ChatRequest
        let events: AsyncStream<RelayEvent>
        let responseId: String
        do {
            (request, events, responseId) = try await service.handle(wire: wire, body: body, apiKey: key)
        } catch {
            let e = AccountRuntime.apiError(error)
            return json(channel, e.status, e.body(for: wire), keepAlive: keepAlive)
        }

        var iterator = events.makeAsyncIterator()
        guard let first = await iterator.next() else {
            let e = APIError(status: 502, type: "api_error", message: "agy produced no response")
            return json(channel, 502, e.body(for: wire), keepAlive: keepAlive)
        }
        if case .failure(let e) = first {
            return json(channel, e.status, e.body(for: wire), keepAlive: keepAlive)
        }

        if !request.stream {
            var aggregator: any WireAggregator
            switch wire {
            case .anthropic: aggregator = AnthropicAggregator(request: request)
            case .chat: aggregator = ChatAggregator(request: request)
            case .responses: aggregator = ResponsesAggregator(request: request, responseId: responseId)
            }
            var failure: APIError?
            aggregator.add(first)
            while let event = await iterator.next() {
                if case .failure(let e) = event { failure = e }
                aggregator.add(event)
            }
            if let failure { return json(channel, failure.status, failure.body(for: wire), keepAlive: keepAlive) }
            return json(channel, 200, aggregator.body, keepAlive: keepAlive)
        }

        var encoder: any WireEncoder
        switch wire {
        case .anthropic: encoder = AnthropicEncoder(request: request)
        case .chat: encoder = ChatEncoder(request: request)
        case .responses: encoder = ResponsesEncoder(request: request, responseId: responseId)
        }
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: "text/event-stream; charset=utf-8")
        headers.add(name: "cache-control", value: "no-cache")
        headers.add(name: "connection", value: "close")
        headers.add(name: "x-accel-buffering", value: "no")
        writeHead(channel, HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))
        let ping = encoder.ping
        let pinger = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if Task.isCancelled { break }
                writeBody(channel, ping)
            }
        }
        writeBody(channel, encoder.frames(for: first).joined())
        while let event = await iterator.next() {
            writeBody(channel, encoder.frames(for: event).joined())
        }
        writeBody(channel, encoder.close().joined())
        pinger.cancel()
        end(channel, keepAlive: false)
    }

    // MARK: - Writing

    static func json(_ channel: Channel, _ status: Int, _ body: JSONValue, keepAlive: Bool) {
        let data = (try? body.encoded()) ?? Data()
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: "application/json")
        headers.add(name: "content-length", value: String(data.count))
        if !keepAlive { headers.add(name: "connection", value: "close") }
        writeHead(channel, HTTPResponseHead(version: .http1_1, status: HTTPResponseStatus(statusCode: status), headers: headers))
        channel.eventLoop.execute {
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
        }
        end(channel, keepAlive: keepAlive)
    }

    private static func writeHead(_ channel: Channel, _ head: HTTPResponseHead) {
        channel.eventLoop.execute { channel.writeAndFlush(HTTPServerResponsePart.head(head), promise: nil) }
    }

    private static func writeBody(_ channel: Channel, _ text: String) {
        guard !text.isEmpty else { return }
        channel.eventLoop.execute {
            var buffer = channel.allocator.buffer(capacity: text.utf8.count)
            buffer.writeString(text)
            channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
        }
    }

    private static func end(_ channel: Channel, keepAlive: Bool) {
        channel.eventLoop.execute {
            let done = channel.writeAndFlush(HTTPServerResponsePart.end(nil))
            if !keepAlive { done.whenComplete { _ in channel.close(promise: nil) } }
        }
    }
}

public enum Agy2APIVersion {
    public static let current = "0.1.0"
}
