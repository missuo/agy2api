import Foundation
import Testing
@testable import Agy2APICore

private func data(_ json: String) -> Data { Data(json.utf8) }

private func events(_ frames: [String]) -> [(String, JSONValue)] {
    frames.joined().components(separatedBy: "\n\n").compactMap { record in
        var name = "", payload = ""
        for line in record.split(separator: "\n") {
            if line.hasPrefix("event: ") { name = String(line.dropFirst(7)) }
            if line.hasPrefix("data: ") { payload = String(line.dropFirst(6)) }
        }
        guard !payload.isEmpty, payload != "[DONE]", let json = try? JSONValue.decode(Data(payload.utf8)) else { return nil }
        return (name, json)
    }
}

@Suite("Anthropic Messages wire")
struct AnthropicWireTests {
    @Test("parses system blocks, interleaved system messages, tools, results, images and effort")
    func parse() throws {
        let request = try AnthropicWire.parse(data(#"""
        {"model":"claude-opus-5-5","stream":true,"output_config":{"effort":"medium"},
         "system":[{"type":"text","text":"Lead."}],
         "tools":[{"name":"Read","description":"r","input_schema":{"type":"object"}},{"type":"web_search_20250305","name":"web_search"}],
         "messages":[
          {"role":"user","content":"hi"},
          {"role":"system","content":[{"type":"text","text":"# Environment"}]},
          {"role":"assistant","content":[{"type":"thinking","thinking":"t","signature":"s"},{"type":"tool_use","id":"t1","name":"Read","input":{"p":"a"}}]},
          {"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"body"},
                                    {"type":"image","source":{"type":"base64","media_type":"image/png","data":"AA"}}]}]}
        """#))
        #expect(request.system == "Lead.")
        #expect(request.effort == "medium")
        #expect(request.tools.map(\.name) == ["Read"])
        #expect(request.turns.count == 3)
        #expect(request.turns[0].blocks == [.text("hi"), .text("[system]\n# Environment")])
        #expect(request.turns[1].blocks.last == .toolUse(id: "t1", name: "Read", input: ["p": "a"]))
        #expect(request.turns[2].blocks.first == .toolResult(toolUseId: "t1", content: [.text("body")], isError: false))
    }

    @Test("thinking budgets map to an effort")
    func budgetEffort() throws {
        let r = try AnthropicWire.parse(data(#"{"model":"m","thinking":{"type":"enabled","budget_tokens":2048},"messages":[{"role":"user","content":"x"}]}"#))
        #expect(r.effort == "low")
    }

    @Test("SSE frames follow the Messages event order")
    func encoder() {
        var e = AnthropicEncoder(request: ChatRequest(wire: .anthropic, model: "m", system: nil, turns: [], tools: [], stream: true))
        var frames: [String] = []
        for ev: RelayEvent in [.thinking("p"), .text("a"), .toolUse(id: "toolu_1", name: "Read", input: ["p": "x"]), .finish(stopReason: "tool_use", usage: RelayUsage(input: 1, output: 2))] {
            frames += e.frames(for: ev)
        }
        #expect(events(frames).map(\.0) == [
            "message_start", "content_block_start", "content_block_delta", "content_block_stop",
            "content_block_start", "content_block_delta", "content_block_stop",
            "content_block_start", "content_block_delta", "content_block_stop", "message_delta", "message_stop",
        ])
    }

    @Test("count_tokens returns an estimate")
    func countTokens() throws {
        let r = try AnthropicWire.countTokens(data(#"{"model":"m","messages":[{"role":"user","content":"\#(String(repeating: "a", count: 400))"}]}"#))
        #expect(r["input_tokens"]?.intValue == 100)
    }
}

@Suite("OpenAI Chat Completions wire")
struct ChatWireTests {
    @Test("parses system/developer, tool calls with string arguments, tool results and data-URL images")
    func parse() throws {
        let r = try ChatWire.parse(data(#"""
        {"model":"gpt-5.5","stream":true,"stream_options":{"include_usage":true},"reasoning_effort":"low",
         "tools":[{"type":"function","function":{"name":"get","description":"d","parameters":{"type":"object"}}}],
         "messages":[
          {"role":"system","content":"S"},{"role":"developer","content":"D"},
          {"role":"user","content":[{"type":"text","text":"look"},{"type":"image_url","image_url":{"url":"data:image/png;base64,AAAA"}}]},
          {"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"get","arguments":"{\"k\":1}"}},
                                                           {"id":"c2","type":"function","function":{"name":"get","arguments":"{}"}}]},
          {"role":"tool","tool_call_id":"c1","content":"one"},{"role":"tool","tool_call_id":"c2","content":"two"}]}
        """#))
        #expect(r.system == "S\n\nD")
        #expect(r.includeUsage)
        #expect(r.effort == "low")
        #expect(r.tools.map(\.name) == ["get"])
        #expect(r.turns.count == 3)
        #expect(r.turns[0].blocks == [.text("look"), .image(data: "AAAA", mimeType: "image/png")])
        #expect(r.turns[1].blocks == [.toolUse(id: "c1", name: "get", input: ["k": 1]), .toolUse(id: "c2", name: "get", input: [:])])
        #expect(r.turns[2].blocks.count == 2)   // both tool results in one user turn
    }

    @Test("streams role, content, indexed tool calls, finish_reason, usage, [DONE]")
    func encoder() {
        var request = ChatRequest(wire: .chat, model: "m", system: nil, turns: [], tools: [], stream: true)
        request.includeUsage = true
        var e = ChatEncoder(request: request)
        var frames: [String] = []
        for ev: RelayEvent in [.text("hi"), .toolUse(id: "call_1", name: "a", input: [:]), .toolUse(id: "call_2", name: "b", input: ["x": 1]),
                                .finish(stopReason: "tool_use", usage: RelayUsage(input: 3, output: 4, cacheRead: 5))] {
            frames += e.frames(for: ev)
        }
        frames += e.close()
        let chunks = events(frames).map(\.1)
        #expect(chunks.first?["choices"]?.arrayValue?.first?["delta"]?["role"] == "assistant")
        let calls = chunks.compactMap { $0["choices"]?.arrayValue?.first?["delta"]?["tool_calls"]?.arrayValue?.first }
        #expect(calls.map { $0["index"]?.intValue } == [0, 1])
        #expect(calls.last?["function"]?["arguments"]?.stringValue == #"{"x":1}"#)
        #expect(chunks.contains { $0["choices"]?.arrayValue?.first?["finish_reason"] == "tool_calls" })
        #expect(chunks.last?["usage"]?["prompt_tokens"]?.intValue == 8)
        #expect(frames.last == "data: [DONE]\n\n")
    }

    @Test("aggregates a non-streaming completion")
    func aggregator() {
        var a = ChatAggregator(request: ChatRequest(wire: .chat, model: "m", system: nil, turns: [], tools: [], stream: false))
        for ev: RelayEvent in [.toolUse(id: "c", name: "n", input: [:]), .finish(stopReason: "tool_use", usage: RelayUsage())] { a.add(ev) }
        let choice = a.body["choices"]?.arrayValue?.first
        #expect(choice?["finish_reason"] == "tool_calls")
        #expect(choice?["message"]?["content"] == .null)
        #expect(choice?["message"]?["tool_calls"]?.arrayValue?.count == 1)
    }
}

@Suite("OpenAI Responses wire")
struct ResponsesWireTests {
    static let codexLike = #"""
    {"model":"gpt-5.5","stream":true,"store":false,"reasoning":{"effort":"xhigh"},"instructions":"",
     "tools":[{"type":"function","name":"exec_command","parameters":{"type":"object"}},
              {"type":"custom","name":"apply_patch","description":"Patch files.","format":{"type":"grammar","syntax":"lark","definition":"start: x"}},
              {"type":"web_search"}],
     "input":[
      {"type":"message","role":"developer","content":[{"type":"input_text","text":"You are Codex, a coding agent based on GPT-5. Be careful."}]},
      {"type":"message","role":"user","content":[{"type":"input_text","text":"do it"}]},
      {"type":"reasoning","summary":[{"type":"summary_text","text":"plan"}]},
      {"type":"custom_tool_call","call_id":"c1","name":"apply_patch","input":"*** Begin Patch"},
      {"type":"custom_tool_call_output","call_id":"c1","output":"Done"},
      {"type":"function_call","call_id":"c2","name":"exec_command","arguments":"{\"cmd\":\"ls\"}"},
      {"type":"function_call_output","call_id":"c2","output":"a.txt"},
      {"type":"message","role":"developer","content":"mid-conversation note"}]}
    """#

    @Test("parses Codex-shaped input: developer messages, custom and function calls, reasoning")
    func parse() throws {
        let r = try ResponsesWire.parse(data(Self.codexLike))
        #expect(r.system == "You are Codex, a coding agent based on GPT-5. Be careful.")
        #expect(r.effort == "xhigh")
        #expect(r.tools.map(\.name) == ["exec_command", "apply_patch"])
        #expect(r.tools[1].freeform)
        #expect(r.tools[1].description.contains("start: x"))
        #expect(r.turns.map(\.role) == [.user, .assistant, .user, .assistant, .user])
        #expect(r.turns[1].blocks == [.thinking("plan"), .toolUse(id: "c1", name: "apply_patch", input: ["input": "*** Begin Patch"])])
        #expect(r.turns[4].blocks.last == .text("[developer]\nmid-conversation note"))
    }

    @Test("streams typed events with sequence numbers; custom tools come back as custom_tool_call")
    func encoder() throws {
        let request = try ResponsesWire.parse(data(Self.codexLike))
        var e = ResponsesEncoder(request: request, responseId: "resp_1")
        var frames: [String] = []
        for ev: RelayEvent in [.thinking("p"), .text("ok"), .toolUse(id: "call_1", name: "apply_patch", input: ["input": "PATCH"]),
                                .toolUse(id: "call_2", name: "exec_command", input: ["cmd": "ls"]),
                                .finish(stopReason: "tool_use", usage: RelayUsage(input: 1, output: 1))] {
            frames += e.frames(for: ev)
        }
        let evs = events(frames)
        #expect(evs.first?.0 == "response.created")
        #expect(evs.last?.0 == "response.completed")
        #expect(evs.map { $0.1["sequence_number"]?.intValue ?? -1 } == Array(0..<evs.count))
        let done = evs.filter { $0.0 == "response.output_item.done" }.map { $0.1["item"]?["type"]?.stringValue }
        #expect(done == ["reasoning", "message", "custom_tool_call", "function_call"])
        let custom = evs.first { $0.0 == "response.output_item.done" && $0.1["item"]?["type"] == "custom_tool_call" }?.1["item"]
        #expect(custom?["input"]?.stringValue == "PATCH")
        #expect(custom?["call_id"]?.stringValue == "call_1")
        let completed = evs.last?.1["response"]
        #expect(completed?["output"]?.arrayValue?.count == 4)
        #expect(completed?["usage"]?["total_tokens"]?.intValue == 2)
    }

    @Test("a plain string input and the aggregator's output_text")
    func stringInputAndAggregate() throws {
        let r = try ResponsesWire.parse(data(#"{"model":"m","input":"hello"}"#))
        #expect(r.turns == [Turn(role: .user, blocks: [.text("hello")])])
        var a = ResponsesAggregator(request: r, responseId: "resp_x")
        for ev: RelayEvent in [.text("a"), .text("b"), .finish(stopReason: "end_turn", usage: RelayUsage())] { a.add(ev) }
        #expect(a.body["output_text"]?.stringValue == "ab")
        #expect(a.body["status"]?.stringValue == "completed")
    }
}

@Suite("Cross-wire transcript matching")
struct TranscriptTests {
    @Test("the same exchange fingerprints the same on every wire")
    func fingerprints() throws {
        let anthropic = try AnthropicWire.parse(data(#"{"model":"m","messages":[{"role":"user","content":"q"},{"role":"assistant","content":[{"type":"text","text":"a"},{"type":"tool_use","id":"t","name":"f","input":{}}]}]}"#))
        let chat = try ChatWire.parse(data(#"{"model":"m","messages":[{"role":"user","content":"q"},{"role":"assistant","content":"a","tool_calls":[{"id":"t","type":"function","function":{"name":"f","arguments":"{}"}}]}]}"#))
        let responses = try ResponsesWire.parse(data(#"{"model":"m","input":[{"role":"user","content":"q"},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"a"}]},{"type":"function_call","call_id":"t","name":"f","arguments":"{}"}]}"#))
        let digests = [anthropic, chat, responses].map { Transcript.digest($0.turns) }
        #expect(Set(digests).count == 1)
    }
}
