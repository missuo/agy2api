import Foundation

/// One signed-in agy account on this host: its own HOME (where `agy` keeps
/// and refreshes its credentials), one `agy acp --process-per-session`, and
/// the ACP sessions behind the conversations it is serving.
///
/// Conversations belong to the API key that opened them: a request is only
/// ever matched against its own key's sessions.
actor AccountRuntime {
    let name: String
    /// nil for the system account: the machine's own agy login and HOME.
    private let home: URL?
    private let workspace: URL
    private let config: ServiceConfig
    private let server: MCPBridgeServer
    private var client: ACPClient?
    private var starting: Task<ACPClient, Error>?
    private var conversations: [String: (owner: String, conversation: Conversation)] = [:]
    private(set) var lastActivity = Date()
    private(set) var models: [JSONValue] = []
    private(set) var sessionsOpened = 0

    init(name: String, home: URL?, workspace: URL, config: ServiceConfig, server: MCPBridgeServer) {
        self.name = name
        self.home = home
        self.workspace = workspace
        self.config = config
        self.server = server
    }

    var liveSessions: Int { conversations.count }

    // MARK: - agy process

    private func connectedClient() async throws -> ACPClient {
        if let client, client.isAlive { return client }
        if let starting { return try await starting.value }
        for entry in conversations.values { await entry.conversation.dispose(reason: "agy restarted") }
        conversations.removeAll()

        let config = config
        let home = home
        let workspace = workspace
        let task = Task<ACPClient, Error> {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            var environment = ProcessInfo.processInfo.environment
            if let home {
                // The account's own HOME and no desktop session bus, so agy
                // uses the file credential store in that HOME.
                environment = [
                    "HOME": home.path,
                    "PATH": environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin",
                    "LANG": environment["LANG"] ?? "C.UTF-8",
                ]
            }
            let client = ACPClient { method, params in
                guard method == "session/request_permission" else {
                    return .failure(ACPError("method not found: \(method)", code: -32601))
                }
                return .success(PermissionPolicy.outcome(params))
            }
            do {
                try await client.start(
                    executable: Accounts.resolveExecutable(config.agyPath, path: environment["PATH"]),
                    arguments: ["--process-per-session"],
                    environment: environment,
                    cwd: workspace
                )
            } catch {
                client.close()
                throw error
            }
            return client
        }
        starting = task
        defer { starting = nil }
        let connected = try await task.value
        client = connected
        return connected
    }

    func shutdown() async {
        for entry in conversations.values { await entry.conversation.dispose(reason: "shutting down") }
        conversations.removeAll()
        client?.close()
        client = nil
    }

    /// Close sessions idle past the timeout; true when none is left and the
    /// account has been unused past `accountIdleTimeout` (stop its agy).
    func sweep() async -> Bool {
        let now = Date()
        for (id, entry) in conversations {
            if await entry.conversation.isIdle,
               await entry.conversation.lastActivity < now.addingTimeInterval(-config.sessionIdleTimeout) {
                conversations[id] = nil
                await entry.conversation.dispose(reason: "idle for \(Int(config.sessionIdleTimeout))s")
            }
        }
        return conversations.isEmpty && lastActivity < now.addingTimeInterval(-config.accountIdleTimeout)
    }

    private func makeRoom() async {
        var idle: [(id: String, conversation: Conversation, last: Date)] = []
        for (id, entry) in conversations where await entry.conversation.isIdle {
            idle.append((id, entry.conversation, await entry.conversation.lastActivity))
        }
        idle.sort { $0.last < $1.last }
        var excess = conversations.count + 1 - config.maxSessionsPerAccount
        for entry in idle where excess > 0 {
            conversations[entry.id] = nil
            await entry.conversation.dispose(reason: "evicted to stay within \(config.maxSessionsPerAccount) sessions")
            excess -= 1
        }
    }

    // MARK: - Requests

    /// The continuation of one of `owner`'s conversations that `request`
    /// extends, if any.
    func match(_ request: ChatRequest, owner: String, setup: String) async -> (Conversation, Conversation.Continuation)? {
        for entry in conversations.values where entry.owner == owner {
            if let continuation = await entry.conversation.match(request, setupDigest: setup) {
                return (entry.conversation, continuation)
            }
        }
        return nil
    }

    /// Answer `request` by continuing `matched`, or in a new session.
    func handle(_ request: ChatRequest, owner: String, setup: String,
                matched: (Conversation, Conversation.Continuation)?) async throws -> AsyncStream<RelayEvent> {
        lastActivity = Date()
        let client = try await connectedClient()
        let (stream, sink) = AsyncStream<RelayEvent>.makeStream()
        if let (conversation, continuation) = matched {
            let kind: String
            switch continuation {
            case .resume: kind = "resume tool results"
            case .prompt: kind = "continue"
            case .fresh: kind = "fresh"
            }
            RelayLog.info("[\(name)] \(RelayLog.user(owner)) session \(conversation.sessionId.prefix(8)) \(kind) \(request.wire.rawValue) model=\(request.slug)")
            watch(sink, conversation)
            await conversation.begin(request, continuation, sink: sink)
            return stream
        }

        await makeRoom()
        let conversation = try await open(request, owner: owner, setup: setup, client: client)
        let split = Transcript.trailingInputStart(request.turns)
        var prompt: [JSONValue] = []
        if let replay = Transcript.historyReplay(Array(request.turns[..<split])) {
            prompt.append(Transcript.textBlock(replay))
        }
        prompt += Transcript.inputBlocks(Array(request.turns[split...]), imagesSupported: Transcript.supportsImages(slug: request.slug))
        watch(sink, conversation)
        await conversation.begin(request, .fresh(prompt), sink: sink)
        return stream
    }

    private func watch(_ sink: AsyncStream<RelayEvent>.Continuation, _ conversation: Conversation) {
        sink.onTermination = { reason in
            if case .cancelled = reason { Task { await conversation.clientGone() } }
        }
    }

    private func open(_ request: ChatRequest, owner: String, setup: String, client: ACPClient) async throws -> Conversation {
        let routeToken = MCPBridgeServer.randomToken()
        let ref = ConversationRef()
        server.setRoute(routeToken, .init(tools: request.tools.map(\.forAgy)) { name, arguments in
            guard let conversation = ref.value else {
                return .init(content: [Transcript.textBlock("The session is not ready.")], isError: true)
            }
            return await conversation.toolCalled(name: name, arguments: arguments)
        })
        func abandon(_ sessionId: String?) async {
            server.setRoute(routeToken, nil)
            if let sessionId { _ = try? await client.request("session/close", params: ["sessionId": .string(sessionId)], timeout: 10) }
        }
        var mcpServers: [JSONValue] = []
        if !request.tools.isEmpty, let entry = server.serverEntry(for: routeToken) { mcpServers.append(entry) }
        let created: JSONValue
        do {
            created = try await client.request("session/new", params: [
                "cwd": .string(workspace.path),
                "mcpServers": .array(mcpServers),
                "_meta": ["antigravity": ["systemPrompt": [
                    "append": .string(Transcript.systemAppendix(system: request.system, hasTools: !request.tools.isEmpty)),
                ]]],
            ], timeout: 90)
        } catch {
            await abandon(nil)
            throw Self.apiError(error)
        }
        guard let sessionId = created["sessionId"]?.stringValue else {
            await abandon(nil)
            throw APIError(status: 502, type: "api_error", message: "agy did not return a session id")
        }
        if let available = created["models"]?["availableModels"]?.arrayValue, !available.isEmpty { models = available }
        guard let current = created["models"]?["currentModelId"]?.stringValue else {
            await abandon(sessionId)
            throw APIError(status: 503, type: "api_error",
                           message: "agy account \(name) could not load models; is it signed in? (agy2api account login \(name))")
        }
        if current != request.slug {
            do {
                _ = try await client.request("session/set_model", params: [
                    "sessionId": .string(sessionId), "modelId": .string(request.slug),
                ], timeout: 30)
            } catch {
                await abandon(sessionId)
                throw APIError(status: 404, type: "not_found_error", message: "unknown model \(request.slug): \(error)")
            }
        }
        sessionsOpened += 1
        RelayLog.info("[\(name)] \(RelayLog.user(owner)) session \(sessionId.prefix(8)) opened \(request.wire.rawValue) model=\(request.slug) tools=\(request.tools.count) turns=\(request.turns.count)")
        let conversation = Conversation(
            sessionId: sessionId, routeToken: routeToken, setupDigest: setup, tokenDigest: nil, modelSlug: request.slug,
            client: client, server: server, toolResultTimeout: config.toolResultTimeout,
            onDispose: { [weak self] id in Task { await self?.forget(id) } }
        )
        ref.value = conversation
        client.setSessionHandler(sessionId) { update in conversation.receive(update: update) }
        conversations[sessionId] = (owner, conversation)
        return conversation
    }

    private func forget(_ sessionId: String) {
        conversations[sessionId] = nil
    }

    /// Learn the model catalog with a throwaway session.
    func availableModels() async throws -> [JSONValue] {
        lastActivity = Date()
        if !models.isEmpty { return models }
        let client = try await connectedClient()
        let created: JSONValue
        do {
            created = try await client.request("session/new", params: ["cwd": .string(workspace.path), "mcpServers": []], timeout: 90)
        } catch {
            throw Self.apiError(error)
        }
        if let id = created["sessionId"]?.stringValue {
            _ = try? await client.request("session/close", params: ["sessionId": .string(id)], timeout: 10)
        }
        models = created["models"]?["availableModels"]?.arrayValue ?? []
        return models
    }

    static func apiError(_ error: Error) -> APIError {
        if let api = error as? APIError { return api }
        let acp = error as? ACPError
        let message = acp?.message ?? "\(error)"
        if acp?.code == -32000 || message.lowercased().contains("auth") {
            return APIError(status: 503, type: "api_error", message: "agy is not signed in: \(message)")
        }
        return APIError(status: 502, type: "api_error", message: "agy: \(message)")
    }
}

extension ToolSpec {
    /// The tool as agy sees it over MCP.
    var forAgy: ToolSpec {
        freeform ? ToolSpec(name: name, description: description, inputSchema: ToolSpec.freeformSchema, freeform: true) : self
    }
}

/// Late-bound pointer from an MCP route to its conversation.
final class ConversationRef: @unchecked Sendable {
    private let lock = NSLock()
    private weak var _value: Conversation?
    var value: Conversation? {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

/// agy's `session/request_permission`: allow the client's MCP tools once,
/// refuse everything else once.
enum PermissionPolicy {
    static func outcome(_ params: JSONValue) -> JSONValue {
        let call = params["toolCall"]
        let name = call?["name"]?.stringValue ?? call?["title"]?.stringValue ?? ""
        let ours = name.hasPrefix(MCPBridgeServer.toolPrefix)
        let options = params["options"]?.arrayValue ?? []
        let kinds = ours ? ["allow_once", "allow_always"] : ["reject_once", "reject_always"]
        let fallbackIds = ours ? ["allow"] : ["deny", "reject"]
        let pick = kinds.lazy.compactMap { kind in options.first { $0["kind"]?.stringValue == kind } }.first
            ?? options.first { fallbackIds.contains($0["optionId"]?.stringValue ?? "") }
        guard let optionId = pick?["optionId"] else { return ["outcome": ["outcome": "cancelled"]] }
        return ["outcome": ["outcome": "selected", "optionId": optionId]]
    }
}
