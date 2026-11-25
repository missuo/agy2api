import Foundation

/// Anthropic Messages (`POST /v1/messages`), as Claude Code speaks it.
enum AnthropicWire {
    static func parse(_ body: Data) throws -> ChatRequest {
        guard let json = try? JSONValue.decode(body), case .object(let root) = json else {
            throw APIError.invalid("request body must be a JSON object")
        }
        guard let model = root["model"]?.stringValue, !model.isEmpty else { throw APIError.invalid("model: field required") }
        guard let messages = root["messages"]?.arrayValue else { throw APIError.invalid("messages: field required") }
        var system = systemText(root["system"]).map { [$0] } ?? []
        var turns: [Turn] = []
        for (index, message) in messages.enumerated() {
            let path = "messages.\(index).content"
            switch message["role"]?.stringValue {
            case "user", "assistant":
                let role = Role(rawValue: message["role"]!.stringValue!)!
                let content = try blocks(message["content"], path: path)
                if let last = turns.last, last.role == role {
                    turns[turns.count - 1].blocks += content
                } else {
                    turns.append(Turn(role: role, blocks: content))
                }
            case "system":
                // Claude Code interleaves system messages: leading ones shape
                // the session, later ones are part of the conversation.
                let text = Transcript.text(of: try blocks(message["content"], path: path))
                if turns.isEmpty {
                    system.append(text)
                } else if turns[turns.count - 1].role == .user {
                    turns[turns.count - 1].blocks.append(.text("[system]\n\(text)"))
                } else {
                    turns.append(Turn(role: .user, blocks: [.text("[system]\n\(text)")]))
                }
            default:
                throw APIError.invalid("messages.\(index).role: must be user, assistant or system")
            }
        }
        let tools = (root["tools"]?.arrayValue ?? []).compactMap { tool -> ToolSpec? in
            // Server tools (web_search_…, code_execution_…) carry a `type`
            // and no schema; only client tools reach agy.
            guard let name = tool["name"]?.stringValue, tool["input_schema"] != nil else { return nil }
            return ToolSpec(name: name, description: tool["description"]?.stringValue ?? "",
                            inputSchema: tool["input_schema"] ?? ["type": "object"])
        }
        var request = ChatRequest(wire: .anthropic, model: model, system: system.isEmpty ? nil : system.joined(separator: "\n\n"), turns: turns,
                                  tools: tools, stream: root["stream"]?.boolValue ?? false)
        request.conversationKey = root["metadata"]?["user_id"]?.stringValue
        if let effort = root["output_config"]?["effort"]?.stringValue {
            request.effort = effort
        } else if let budget = root["thinking"]?["budget_tokens"]?.intValue {
            request.effort = budget <= 4096 ? "low" : budget <= 16384 ? "medium" : "high"
        }
        return request
    }

    static func systemText(_ value: JSONValue?) -> String? {
        switch value {
        case .string(let s)?: return s.isEmpty ? nil : s
        case .array(let parts)?:
            let text = parts.compactMap { $0["text"]?.stringValue }.joined(separator: "\n\n")
            return text.isEmpty ? nil : text
        default: return nil
        }
    }

    static func blocks(_ content: JSONValue?, path: String) throws -> [Block] {
        switch content {
        case .string(let s)?: return [.text(s)]
        case .array(let items)?: return try items.enumerated().compactMap { try block($1, path: "\(path).\($0)") }
        case nil, .null?: return []
        default: throw APIError.invalid("\(path): must be a string or an array of content blocks")
        }
    }

    static func block(_ item: JSONValue, path: String) throws -> Block? {
        switch item["type"]?.stringValue {
        case "text":
            return .text(item["text"]?.stringValue ?? "")
        case "image":
            let source = item["source"]
            if source?["type"]?.stringValue == "base64", let data = source?["data"]?.stringValue,
               let mime = source?["media_type"]?.stringValue {
                return .image(data: data, mimeType: mime)
            }
            return .text("[image: \(source?["url"]?.stringValue ?? "?")]")
        case "tool_use", "server_tool_use":
            guard let id = item["id"]?.stringValue, let name = item["name"]?.stringValue else {
                throw APIError.invalid("\(path): tool_use needs id and name")
            }
            return .toolUse(id: id, name: name, input: item["input"] ?? .object([:]))
        case "tool_result":
            guard let id = item["tool_use_id"]?.stringValue else { throw APIError.invalid("\(path): tool_result needs tool_use_id") }
            return .toolResult(toolUseId: id, content: try blocks(item["content"], path: "\(path).content"),
                               isError: item["is_error"]?.boolValue ?? false)
        case "thinking":
            return .thinking(item["thinking"]?.stringValue ?? "")
        case "document":
            if item["source"]?["type"]?.stringValue == "text", let text = item["source"]?["data"]?.stringValue {
                return .text("[document: \(item["title"]?.stringValue ?? "document")]\n\(text)")
            }
            return .text("[document omitted: \(item["title"]?.stringValue ?? "document")]")
        default:
            return nil
        }
    }

    /// `POST /v1/messages/count_tokens`: an estimate (agy has no counter);
    /// Claude Code uses it to decide when to compact.
    static func countTokens(_ body: Data) throws -> JSONValue {
        let request = try parse(body)
        var chars = (request.system ?? "").count
        for turn in request.turns {
            for block in turn.blocks {
                switch block {
                case .text(let t), .thinking(let t): chars += t.count
                case .image: chars += 1600 * 4
                case .toolUse(_, let name, let input): chars += name.count + input.compactString.count
                case .toolResult(_, let content, _): chars += Transcript.text(of: content).count
                }
            }
        }
        for tool in request.tools { chars += tool.name.count + tool.description.count + tool.inputSchema.compactString.count }
        return ["input_tokens": .int(max(1, chars / 4))]
    }
}

/// Anthropic SSE.
struct AnthropicEncoder: WireEncoder {
    private enum Open { case text, thinking }
    let messageId = randomId("msg_agy_")
    let model: String
    private var started = false
    private var index = -1
    private var open: Open?

    init(request: ChatRequest) {
        model = request.model
    }

    mutating func frames(for event: RelayEvent) -> [String] {
        var out: [String] = []
        if !started {
            started = true
            out.append(frame("message_start", [
                "type": "message_start",
                "message": [
                    "id": .string(messageId), "type": "message", "role": "assistant", "model": .string(model),
                    "content": [], "stop_reason": nil, "stop_sequence": nil,
                    "usage": ["input_tokens": 0, "output_tokens": 0],
                ],
            ]))
        }
        switch event {
        case .text(let text):
            if open != .text { out += closeBlock(); out += openBlock(.text, ["type": "text", "text": ""]) }
            out.append(delta(["type": "text_delta", "text": .string(text)]))
        case .thinking(let text):
            if open != .thinking { out += closeBlock(); out += openBlock(.thinking, ["type": "thinking", "thinking": ""]) }
            out.append(delta(["type": "thinking_delta", "thinking": .string(text)]))
        case .toolUse(let id, let name, let input):
            out += closeBlock()
            index += 1
            out.append(frame("content_block_start", [
                "type": "content_block_start", "index": .int(index),
                "content_block": ["type": "tool_use", "id": .string(id), "name": .string(name), "input": [:]],
            ]))
            out.append(delta(["type": "input_json_delta", "partial_json": .string(input.compactString)]))
            out.append(frame("content_block_stop", ["type": "content_block_stop", "index": .int(index)]))
        case .finish(let stop, let usage):
            out += closeBlock()
            out.append(frame("message_delta", [
                "type": "message_delta",
                "delta": ["stop_reason": .string(stop), "stop_sequence": nil],
                "usage": [
                    "input_tokens": .int(usage.input), "output_tokens": .int(usage.output),
                    "cache_read_input_tokens": .int(usage.cacheRead), "cache_creation_input_tokens": .int(usage.cacheWrite),
                ],
            ]))
            out.append(frame("message_stop", ["type": "message_stop"]))
        case .failure(let error):
            out.append(frame("error", error.body(for: .anthropic)))
        }
        return out
    }

    mutating func close() -> [String] { [] }

    var ping: String { "event: ping\ndata: {\"type\":\"ping\"}\n\n" }

    private mutating func openBlock(_ kind: Open, _ block: JSONValue) -> [String] {
        index += 1
        open = kind
        return [frame("content_block_start", ["type": "content_block_start", "index": .int(index), "content_block": block])]
    }

    private mutating func closeBlock() -> [String] {
        guard open != nil else { return [] }
        open = nil
        return [frame("content_block_stop", ["type": "content_block_stop", "index": .int(index)])]
    }

    private func delta(_ d: JSONValue) -> String {
        frame("content_block_delta", ["type": "content_block_delta", "index": .int(index), "delta": d])
    }
}

/// Anthropic non-streaming body.
struct AnthropicAggregator: WireAggregator {
    let messageId = randomId("msg_agy_")
    let model: String
    private var content: [JSONValue] = []
    private var stop: String?
    private var usage = RelayUsage()

    init(request: ChatRequest) {
        model = request.model
    }

    mutating func add(_ event: RelayEvent) {
        switch event {
        case .text(let t): appendText("text", t)
        case .thinking(let t): appendText("thinking", t)
        case .toolUse(let id, let name, let input):
            content.append(["type": "tool_use", "id": .string(id), "name": .string(name), "input": input])
        case .finish(let s, let u): stop = s; usage = u
        case .failure: break
        }
    }

    private mutating func appendText(_ type: String, _ text: String) {
        if case .object(var last)? = content.last, last["type"]?.stringValue == type {
            last[type] = .string((last[type]?.stringValue ?? "") + text)
            content[content.count - 1] = .object(last)
        } else {
            var block: [String: JSONValue] = ["type": .string(type)]
            block[type] = .string(text)
            content.append(.object(block))
        }
    }

    var body: JSONValue {
        [
            "id": .string(messageId), "type": "message", "role": "assistant", "model": .string(model),
            "content": .array(content), "stop_reason": stop.map { .string($0) } ?? .null, "stop_sequence": nil,
            "usage": [
                "input_tokens": .int(usage.input), "output_tokens": .int(usage.output),
                "cache_read_input_tokens": .int(usage.cacheRead), "cache_creation_input_tokens": .int(usage.cacheWrite),
            ],
        ]
    }
}

/// SSE frame `event: name` + `data: json`.
func frame(_ name: String, _ data: JSONValue) -> String {
    "event: \(name)\ndata: \(data.compactString)\n\n"
}

/// How a wire streams and aggregates relay events.
protocol WireEncoder {
    mutating func frames(for event: RelayEvent) -> [String]
    /// Frames after the last event (Chat's `[DONE]`).
    mutating func close() -> [String]
    /// A keep-alive frame for long silences.
    var ping: String { get }
}

protocol WireAggregator {
    mutating func add(_ event: RelayEvent)
    var body: JSONValue { get }
}
