import Foundation
import NIOConcurrencyHelpers

/// Request logic independent of HTTP: authenticate the API key, parse the
/// wire, pick the agy account and session, and stream relay events.
public final class Agy2APIService: Sendable {
    public let config: ServiceConfig
    let server = MCPBridgeServer()
    private let keys: KeyStore
    private let runtimes = NIOLockedValueBox([String: AccountRuntime]())
    private let responses = ResponseStore()
    private let sweeper = NIOLockedValueBox<Task<Void, Never>?>(nil)

    public init(config: ServiceConfig) {
        self.config = config
        self.keys = KeyStore(config)
    }

    public func start() async throws {
        try await server.start()
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                await self?.sweep()
            }
        }
        sweeper.withLockedValue { $0 = task }
    }

    public func stop() async {
        sweeper.withLockedValue { $0?.cancel() }
        let all = runtimes.withLockedValue { r -> [AccountRuntime] in defer { r.removeAll() }; return Array(r.values) }
        for runtime in all { await runtime.shutdown() }
        server.stop()
    }

    private func sweep() async {
        for (name, runtime) in runtimes.withLockedValue({ $0 }) where await runtime.sweep() {
            await runtime.shutdown()
            runtimes.withLockedValue { $0[name] = nil }
        }
        await responses.prune()
    }

    // MARK: - Accounts

    /// Runtimes for every signed-in account (new logins are picked up live).
    private func accountRuntimes() -> [AccountRuntime] {
        let names = config.systemAccount ? ["system"] : Accounts.list(config)
        return runtimes.withLockedValue { runtimes in
            names.map { name in
                if let existing = runtimes[name] { return existing }
                let runtime = AccountRuntime(
                    name: name,
                    home: config.systemAccount ? nil : Accounts.home(config, name: name),
                    workspace: config.root.appendingPathComponent("workspaces/\(name)", isDirectory: true),
                    config: config, server: server
                )
                runtimes[name] = runtime
                return runtime
            }
        }
    }

    /// Live account runtimes (tests).
    func debugRuntimes() -> [AccountRuntime] {
        runtimes.withLockedValue { Array($0.values) }
    }

    // MARK: - Auth

    /// The API key's name, or the local user in system-account mode.
    func authorize(_ presented: String?) throws -> String {
        if config.systemAccount { return "local" }
        guard let presented, !presented.isEmpty else { throw APIError.auth("missing API key (Authorization: Bearer sk-agy-…)") }
        guard let owner = keys.owner(of: presented) else { throw APIError.auth("invalid API key") }
        return owner
    }

    // MARK: - Models

    /// agy model slugs known without a live session (agy 1.5.x).
    public static let knownSlugs: Set<String> = [
        "gemini-4-neon-high", "gemini-4-neon-xhigh", "gemini-4-neon-medium", "gemini-4-neon-low",
        "gemini-4-carbon-medium", "gemini-4-carbon-high", "gemini-4-carbon-low",
        "gemini-4-argon-medium", "gemini-4-argon-high", "gemini-4-argon-low",
        "gemini-4-hydrogen-high", "gemini-4-hydrogen-xhigh", "gemini-4-hydrogen-medium", "gemini-4-hydrogen-low",
        "gemini-pro-orchestrator-neon", "gemini-pro-orchestrator", "gemini-pro-orchestrator-argon",
        "gemini-3.8-flash-high", "gemini-3.8-flash-medium", "gemini-3.8-flash-low",
        "claude-opus-5-5-low", "claude-opus-5-5-medium", "claude-opus-5-5-high",
        "claude-sonnet-5-5-low", "claude-sonnet-5-5-medium", "claude-sonnet-5-5-high",
        "gpt-oss-120b-medium",
    ]

    /// Slugs agy offers: the bundled list plus what live sessions reported.
    func availableSlugs() async -> Set<String> {
        await liveSlugs().union(Self.knownSlugs)
    }

    private func liveSlugs() async -> Set<String> {
        var out: Set<String> = []
        for runtime in accountRuntimes() {
            for model in await runtime.models { if let id = model["modelId"]?.stringValue { out.insert(id) } }
        }
        return out
    }

    public func models() async throws -> [(id: String, name: String)] {
        var catalog: [JSONValue] = []
        for runtime in accountRuntimes() {
            catalog = (try? await runtime.availableModels()) ?? []
            if !catalog.isEmpty { break }
        }
        var out: [(id: String, name: String)] = catalog.isEmpty
            ? Self.knownSlugs.sorted().map { ($0, $0) }
            : catalog.compactMap { m in m["modelId"]?.stringValue.map { ($0, m["name"]?.stringValue ?? $0) } }
        // Client-facing names from models.json, so pickers can offer them.
        for (alias, target) in ModelMap.load(config).aliases.sorted(by: { $0.key < $1.key }) where !alias.contains("*") {
            out.append((alias, "\(alias) → \(target)"))
        }
        return out
    }

    // MARK: - Requests

    /// Parse and answer one request on `wire`.
    public func handle(wire: Wire, body: Data, apiKey: String?) async throws -> (request: ChatRequest, events: AsyncStream<RelayEvent>, responseId: String) {
        let owner = try authorize(apiKey)
        var request: ChatRequest
        switch wire {
        case .anthropic: request = try AnthropicWire.parse(body)
        case .chat: request = try ChatWire.parse(body)
        case .responses: request = try ResponsesWire.parse(body)
        }
        if let previous = request.previousResponseId {
            guard let prior = await responses.turns(for: previous, owner: owner) else {
                throw APIError(status: 400, type: "invalid_request_error", message: "Previous response with id '\(previous)' not found.")
            }
            request.turns = prior + request.turns
        }
        guard request.turns.last?.role == .user else { throw APIError.invalid("the last message must come from the user") }
        request.system = SystemPromptFilter.apply(request.system, mode: config.systemPromptMode(for: request.wire))
        let (slug, rule) = ModelMap.load(config).resolve(request.model, available: await availableSlugs(), effort: request.effort)
        request.slug = slug
        if slug != request.model {
            RelayLog.info("\(RelayLog.user(owner)) model \(request.model) -> \(slug) (\(rule))")
        }

        let accounts = accountRuntimes()
        guard !accounts.isEmpty else {
            throw APIError(status: 503, type: "api_error", message: "no agy account is signed in (agy2api account login <name>)")
        }
        let setup = Transcript.setupDigest(system: request.system, tools: request.tools)
        var target: AccountRuntime?
        var matched: (Conversation, Conversation.Continuation)?
        for account in accounts {
            if let m = await account.match(request, owner: owner, setup: setup) { target = account; matched = m; break }
        }
        if target == nil {
            var best: (AccountRuntime, Int)?
            for account in accounts.shuffled() {
                let load = await account.liveSessions
                if best == nil || load < best!.1 { best = (account, load) }
            }
            target = best?.0
        }
        let inner: AsyncStream<RelayEvent>
        do {
            inner = try await target!.handle(request, owner: owner, setup: setup, matched: matched)
        } catch {
            throw AccountRuntime.apiError(error)
        }

        let responseId = randomId("resp_")
        guard wire == .responses else { return (request, inner, responseId) }
        // Responses: remember the transcript so `previous_response_id` works.
        let (outer, sink) = AsyncStream<RelayEvent>.makeStream()
        let store = responses
        let turns = request.turns
        let forward = Task {
            var text = ""
            var calls: [Block] = []
            for await event in inner {
                switch event {
                case .text(let t): text += t
                case .toolUse(let id, let name, let input): calls.append(.toolUse(id: id, name: name, input: input))
                case .finish:
                    await store.record(responseId, owner: owner, turns: turns + [Turn(role: .assistant, blocks: [.text(text)] + calls)])
                default: break
                }
                sink.yield(event)
            }
            sink.finish()
        }
        sink.onTermination = { reason in
            if case .cancelled = reason { forward.cancel() }
        }
        return (request, outer, responseId)
    }
}

/// Transcripts behind Responses ids, for `previous_response_id`.
actor ResponseStore {
    private var entries: [String: (owner: String, turns: [Turn], expires: Date)] = [:]
    static let lifetime: TimeInterval = 60 * 60
    static let capacity = 2000

    func record(_ id: String, owner: String, turns: [Turn]) {
        entries[id] = (owner, turns, Date().addingTimeInterval(Self.lifetime))
        if entries.count > Self.capacity {
            for (key, _) in entries.sorted(by: { $0.value.expires < $1.value.expires }).prefix(entries.count - Self.capacity) {
                entries[key] = nil
            }
        }
    }

    func turns(for id: String, owner: String) -> [Turn]? {
        guard let entry = entries[id], entry.owner == owner, entry.expires > Date() else { return nil }
        return entry.turns
    }

    func prune() {
        let now = Date()
        entries = entries.filter { $0.value.expires > now }
    }
}
