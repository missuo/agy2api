import Foundation
import Testing
@testable import Agy2APICore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private func tempConfig() -> ServiceConfig {
    var c = ServiceConfig(dataRoot: FileManager.default.temporaryDirectory.appendingPathComponent("agy2api-test-\(UUID().uuidString)").path)
    c.port = 0
    return c
}

@Suite("Model map")
struct ModelMapTests {
    let agy = Agy2APIService.knownSlugs

    @Test("families, efforts, small models and the default")
    func resolution() {
        let map = ModelMap()
        #expect(map.resolve("claude-opus-5-5", available: agy).slug == "claude-opus-5-5-high")
        #expect(map.resolve("anthropic/claude-opus-5.5-20260101", available: agy, effort: "low").slug == "claude-opus-5-5-low")
        #expect(map.resolve("agy/gemini-4-neon-medium", available: agy).slug == "gemini-4-neon-medium")
        #expect(map.resolve("gemini-4-neon", available: agy, effort: "max").slug == "gemini-4-neon-xhigh")
        #expect(map.resolve("claude-haiku-4-5-20251001", available: agy).slug == map.fastModel)
        #expect(map.resolve("gpt-5.5", available: agy).slug == map.defaultModel)
    }

    @Test("aliases win, globs match, and a family target follows the effort")
    func aliases() {
        var map = ModelMap()
        map.aliases = ["claude-opus-5-5": "gemini-4-neon", "gpt-*": "claude-sonnet-5-5-low", "GPT-5.5": "gemini-4-hydrogen-high"]
        #expect(map.resolve("claude-opus-5-5", available: agy, effort: "medium").slug == "gemini-4-neon-medium")
        #expect(map.resolve("claude-opus-5-5", available: agy).slug == "gemini-4-neon-high")
        #expect(map.resolve("gpt-5.5", available: agy).slug == "gemini-4-hydrogen-high")   // exact beats glob
        #expect(map.resolve("gpt-5-codex", available: agy).slug == "claude-sonnet-5-5-low")
    }

    @Test("models.json round-trips")
    func storage() throws {
        let config = tempConfig()
        defer { try? FileManager.default.removeItem(atPath: config.dataRoot) }
        var map = ModelMap()
        map.aliases["x"] = "y"
        map.defaultModel = "gemini-4-carbon-high"
        try map.save(config)
        let loaded = ModelMap.load(config)
        #expect(loaded.aliases == ["x": "y"])
        #expect(loaded.defaultModel == "gemini-4-carbon-high")
    }
}

@Suite("System prompt filter")
struct SystemPromptFilterTests {
    let claudeCode = """
    x-anthropic-billing-header: cc_version=2.1.332; cc_entrypoint=cli;
    You are Claude Code, Anthropic's official CLI for Claude.
    You are an interactive agent that helps users with software engineering tasks.
    """

    @Test("strip-identity removes only the self-identification and billing lines")
    func strip() {
        let out = SystemPromptFilter.apply(claudeCode, mode: .stripIdentity)
        #expect(out == "You are an interactive agent that helps users with software engineering tasks.")
        #expect(SystemPromptFilter.apply("You are Codex, a coding agent based on GPT-5. Be careful.", mode: .stripIdentity) == "Be careful.")
        #expect(SystemPromptFilter.apply("You are a Claude agent, built on Anthropic's Claude Agent SDK.", mode: .stripIdentity) == nil)
        #expect(SystemPromptFilter.apply("Plain instructions.", mode: .stripIdentity) == "Plain instructions.")
    }

    @Test("keep and drop")
    func modes() {
        #expect(SystemPromptFilter.apply(claudeCode, mode: .keep) == claudeCode)
        #expect(SystemPromptFilter.apply(claudeCode, mode: .drop) == nil)
        var config = tempConfig()
        config.systemPromptModeByWire[.anthropic] = .drop
        #expect(config.systemPromptMode(for: .anthropic) == .drop)
        #expect(config.systemPromptMode(for: .responses) == .stripIdentity)
    }
}

@Suite("API keys")
struct KeyStoreTests {
    @Test("keys are stored hashed in a 0600 file and resolve to their name")
    func keys() throws {
        let config = tempConfig()
        defer { try? FileManager.default.removeItem(atPath: config.dataRoot) }
        let store = KeyStore(config)
        let key = try store.add(name: "laptop")
        #expect(key.hasPrefix("sk-agy-") && key.count == 7 + 64)
        #expect(store.owner(of: key) == "laptop")
        #expect(store.owner(of: key + "x") == nil)
        let file = try String(contentsOf: store.file, encoding: .utf8)
        #expect(!file.contains(key))
        let mode = (try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)
        #expect(try store.remove(name: "laptop"))
        #expect(store.owner(of: key) == nil)
    }
}

@Suite("HTTP server")
struct ServerTests {
    @Test("health, auth, routing and errors in each wire's envelope")
    func routes() async throws {
        let config = tempConfig()
        defer { try? FileManager.default.removeItem(atPath: config.dataRoot) }
        let key = try KeyStore(config).add(name: "t")
        let server = Agy2APIServer(config: config)
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let base = "http://127.0.0.1:\(port)"

        func call(_ method: String, _ path: String, _ body: String? = nil, headers: [String: String] = [:]) async throws -> (Int, JSONValue?) {
            var r = URLRequest(url: URL(string: base + path)!)
            r.httpMethod = method
            if let body { r.httpBody = Data(body.utf8) }
            for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
            let (data, response) = try await URLSession.shared.data(for: r)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, try? JSONValue.decode(data))
        }
        let chat = #"{"model":"gpt-5.5","messages":[{"role":"user","content":"hi"}]}"#

        #expect(try await call("GET", "/healthz").0 == 200)
        let (noKey, noKeyBody) = try await call("POST", "/v1/chat/completions", chat)
        #expect(noKey == 401)
        #expect(noKeyBody?["error"]?["code"]?.stringValue == "invalid_api_key")
        let (badKey, _) = try await call("POST", "/v1/messages", #"{"model":"m","messages":[{"role":"user","content":"x"}]}"#, headers: ["x-api-key": "nope"])
        #expect(badKey == 401)
        // A valid key with no agy account signed in.
        let (noAccount, noAccountBody) = try await call("POST", "/chat/completions", chat, headers: ["authorization": "Bearer \(key)"])
        #expect(noAccount == 503)
        #expect(noAccountBody?["error"]?["message"]?.stringValue?.contains("account login") == true)
        let (badBody, badBodyJSON) = try await call("POST", "/v1/responses", "{}", headers: ["authorization": "Bearer \(key)"])
        #expect(badBody == 400)
        #expect(badBodyJSON?["error"]?["type"]?.stringValue == "invalid_request_error")
        let (count, countBody) = try await call("POST", "/v1/messages/count_tokens?beta=true",
                                                #"{"model":"m","messages":[{"role":"user","content":"abcdabcd"}]}"#, headers: ["x-api-key": key])
        #expect(count == 200 && countBody?["input_tokens"]?.intValue == 2)
        let (models, modelsBody) = try await call("GET", "/v1/models", headers: ["authorization": "Bearer \(key)"])
        #expect(models == 200 && modelsBody?["object"] == "list")
        let (anthropicModels, anthropicBody) = try await call("GET", "/v1/models", headers: ["x-api-key": key, "anthropic-version": "2023-06-01"])
        #expect(anthropicModels == 200 && anthropicBody?["data"]?.arrayValue?.first?["type"] == "model")
        #expect(try await call("GET", "/nope").0 == 404)
    }
}
