import Foundation
import Testing
@testable import Agy2APICore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A tool round trip on every wire against this machine's signed-in agy.
/// Gated behind `AGY2API_LIVE=1`.
@Suite("Live: all three wires against agy")
struct LiveTests {
    static func post(_ url: URL, _ body: JSONValue) async throws -> String {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.httpBody = try body.encoded()
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        r.timeoutInterval = 300
        let (data, _) = try await URLSession.shared.data(for: r)
        return String(decoding: data, as: UTF8.self)
    }

    static func sse(_ text: String) -> [JSONValue] {
        text.components(separatedBy: "\n\n").compactMap { record in
            guard let line = record.split(separator: "\n").first(where: { $0.hasPrefix("data: ") }) else { return nil }
            return try? JSONValue.decode(Data(line.dropFirst(6).utf8))
        }
    }

    @Test("Messages, Chat Completions and Responses each call a tool and use its result")
    func roundTrips() async throws {
        guard ProcessInfo.processInfo.environment["AGY2API_LIVE"] == "1" else {
            print("[skipped] set AGY2API_LIVE=1 to run")
            return
        }
        var config = ServiceConfig(dataRoot: FileManager.default.temporaryDirectory.appendingPathComponent("agy2api-live-\(UUID())").path)
        config.port = 0
        config.systemAccount = true
        config.agyPath = ProcessInfo.processInfo.environment["AGY_PATH"] ?? (NSHomeDirectory() + "/.local/bin/agy")
        let server = Agy2APIServer(config: config)
        let port = try await server.start()
        let dataRoot = config.dataRoot
        defer { Task { await server.stop(); try? FileManager.default.removeItem(atPath: dataRoot) } }
        let base = "http://127.0.0.1:\(port)/v1"
        let model = "agy/gemini-3.8-flash-low"
        let ask = "Call get_secret with key alpha, then tell me the number."
        let schema: JSONValue = ["type": "object", "properties": ["key": ["type": "string"]], "required": ["key"]]

        // Anthropic Messages.
        let aTools: JSONValue = [["name": "get_secret", "description": "Returns the secret for a key.", "input_schema": schema]]
        var aMessages: [JSONValue] = [["role": "user", "content": .string(ask)]]
        let a1 = Self.sse(try await Self.post(URL(string: "\(base)/messages")!, ["model": .string(model), "max_tokens": 512, "stream": true, "tools": aTools, "messages": .array(aMessages)]))
        let aFound = a1.first(where: { $0["content_block"]?["type"] == "tool_use" })?["content_block"]
        let aCall = try #require(aFound)
        aMessages.append(["role": "assistant", "content": [["type": "tool_use", "id": aCall["id"]!, "name": "get_secret", "input": ["key": "alpha"]]]])
        aMessages.append(["role": "user", "content": [["type": "tool_result", "tool_use_id": aCall["id"]!, "content": "the secret is 4217"]]])
        let a2 = Self.sse(try await Self.post(URL(string: "\(base)/messages")!, ["model": .string(model), "max_tokens": 512, "stream": true, "tools": aTools, "messages": .array(aMessages)]))
        let aText = a2.compactMap { $0["delta"]?["text"]?.stringValue }.joined()
        #expect(aText.contains("4217"), "messages: \(aText)")

        // Chat Completions.
        let cTools: JSONValue = [["type": "function", "function": ["name": "get_secret", "description": "Returns the secret for a key.", "parameters": schema]]]
        var cMessages: [JSONValue] = [["role": "user", "content": .string(ask)]]
        let c1 = Self.sse(try await Self.post(URL(string: "\(base)/chat/completions")!, ["model": .string(model), "stream": true, "tools": cTools, "messages": .array(cMessages)]))
        let cFound: JSONValue? = c1.compactMap { chunk -> JSONValue? in
            let delta = chunk["choices"]?.arrayValue?.first?["delta"]
            return delta?["tool_calls"]?.arrayValue?.first
        }.first
        let cCall = try #require(cFound)
        cMessages.append(["role": "assistant", "content": nil, "tool_calls": [cCall]])
        cMessages.append(["role": "tool", "tool_call_id": cCall["id"]!, "content": "the secret is 4217"])
        let c2 = Self.sse(try await Self.post(URL(string: "\(base)/chat/completions")!, ["model": .string(model), "stream": true, "tools": cTools, "messages": .array(cMessages)]))
        let cText = c2.compactMap { $0["choices"]?.arrayValue?.first?["delta"]?["content"]?.stringValue }.joined()
        #expect(cText.contains("4217"), "chat: \(cText)")

        // Responses, continued with previous_response_id.
        let rTools: JSONValue = [["type": "function", "name": "get_secret", "description": "Returns the secret for a key.", "parameters": schema]]
        let r1 = Self.sse(try await Self.post(URL(string: "\(base)/responses")!, ["model": .string(model), "stream": true, "tools": rTools, "input": .string(ask)]))
        let r1Found = r1.last(where: { $0["type"] == "response.completed" })?["response"]
        let r1Done = try #require(r1Found)
        let rFound = r1Done["output"]?.arrayValue?.first(where: { $0["type"] == "function_call" })
        let rCall = try #require(rFound)
        let r2 = Self.sse(try await Self.post(URL(string: "\(base)/responses")!, [
            "model": .string(model), "stream": true, "tools": rTools, "previous_response_id": r1Done["id"]!,
            "input": [["type": "function_call_output", "call_id": rCall["call_id"]!, "output": "the secret is 4217"]],
        ]))
        let rText = r2.compactMap { $0["type"] == "response.output_text.delta" ? $0["delta"]?.stringValue : nil }.joined()
        #expect(rText.contains("4217"), "responses: \(rText)")

        // Each wire's second request resumed its parked tool call: 3 sessions, not 6.
        var opened = 0
        for runtime in server.service.debugRuntimes() { opened += await runtime.sessionsOpened }
        #expect(opened == 3)
    }
}
