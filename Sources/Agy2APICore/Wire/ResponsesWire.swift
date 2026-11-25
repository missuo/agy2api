import Foundation

/// OpenAI Responses (`POST /v1/responses`), as Codex speaks it.
enum ResponsesWire {
    static func parse(_ body: Data) throws -> ChatRequest {
        guard let json = try? JSONValue.decode(body), case .object(let root) = json else {
            throw APIError.invalid("request body must be a JSON object")
        }
        guard let model = root["model"]?.stringValue, !model.isEmpty else { throw APIError.invalid("model: field required") }

        var system: [String] = []
        if let instructions = root["instructions"]?.stringValue, !instructions.isEmpty { system.append(instructions) }
        var turns: [Turn] = []
        func append(_ role: Role, _ blocks: [Block]) {
            guard !blocks.isEmpty else { return }
            if let last = turns.last, last.role == role {
                turns[turns.count - 1].blocks += blocks
            } else {
                turns.append(Turn(role: role, blocks: blocks))
            }
        }

        switch root["input"] {
        case .string(let s)?:
            append(.user, [.text(s)])
        case .array(let items)?:
            for (index, item) in items.enumerated() {
                let path = "input.\(index)"
                let type = item["type"]?.stringValue ?? (item["role"] != nil ? "message" : "")
                switch type {
                case "message":
                    let role = item["role"]?.stringValue ?? "user"
                    let blocks = try content(item["content"], path: path)
                    switch role {
                    case "system", "developer":
                        let text = Transcript.text(of: blocks)
                        // Leading instructions shape the session; later ones
                        // are part of the conversation.
                        if turns.isEmpty { system.append(text) } else { append(.user, [.text("[\(role)]\n\(text)")]) }
                    case "assistant":
                        append(.assistant, blocks.isEmpty ? [.text("")] : blocks)
                    default:
                        append(.user, blocks)
                    }
                case "function_call":
                    guard let id = item["call_id"]?.stringValue, let name = item["name"]?.stringValue else {
                        throw APIError.invalid("\(path): function_call needs call_id and name")
                    }
                    append(.assistant, [.toolUse(id: id, name: name, input: ChatWire.arguments(item["arguments"]))])
                case "custom_tool_call":
                    guard let id = item["call_id"]?.stringValue, let name = item["name"]?.stringValue else {
                        throw APIError.invalid("\(path): custom_tool_call needs call_id and name")
                    }
                    append(.assistant, [.toolUse(id: id, name: name, input: ["input": .string(item["input"]?.stringValue ?? "")])])
                case "function_call_output", "custom_tool_call_output":
                    guard let id = item["call_id"]?.stringValue else { throw APIError.invalid("\(path): output needs call_id") }
                    let output: [Block]
                    switch item["output"] {
                    case .string(let s)?: output = [.text(s)]
                    case .array?: output = try content(item["output"], path: "\(path).output")
                    default: output = [.text(item["output"]?.compactString ?? "")]
                    }
                    append(.user, [.toolResult(toolUseId: id, content: output, isError: false)])
                case "reasoning":
                    let summary = (item["summary"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
                    append(.assistant, [.thinking(summary)])
                default:
                    // item_reference, local_shell_call, web_search_call…:
                    // nothing agy can act on.
                    continue
                }
            }
        default:
            throw APIError.invalid("input: field required")
        }

        let tools = (root["tools"]?.arrayValue ?? []).compactMap { tool -> ToolSpec? in
            guard let name = tool["name"]?.stringValue else { return nil }
            switch tool["type"]?.stringValue ?? "function" {
            case "function":
                return ToolSpec(name: name, description: tool["description"]?.stringValue ?? "",
                                inputSchema: tool["parameters"] ?? ["type": "object", "properties": [:]])
            case "custom":
                var description = tool["description"]?.stringValue ?? ""
                if let definition = tool["format"]?["definition"]?.stringValue {
                    description += "\n\nThe `input` string must follow this \(tool["format"]?["syntax"]?.stringValue ?? "") grammar:\n\(definition)"
                }
                return ToolSpec(name: name, description: description, inputSchema: ToolSpec.freeformSchema, freeform: true)
            default:
                return nil
            }
        }
        var request = ChatRequest(wire: .responses, model: model, system: system.isEmpty ? nil : system.joined(separator: "\n\n"),
                                  turns: turns, tools: tools, stream: root["stream"]?.boolValue ?? false)
        request.previousResponseId = root["previous_response_id"]?.stringValue
        request.effort = root["reasoning"]?["effort"]?.stringValue
        request.conversationKey = root["prompt_cache_key"]?.stringValue
        return request
    }

    static func content(_ value: JSONValue?, path: String) throws -> [Block] {
        switch value {
        case .string(let s)?: return [.text(s)]
        case .array(let parts)?:
            return parts.compactMap { part -> Block? in
                switch part["type"]?.stringValue {
                case "input_text", "output_text", "text", "summary_text":
                    return .text(part["text"]?.stringValue ?? "")
                case "refusal":
                    return .text(part["refusal"]?.stringValue ?? "")
                case "input_image":
                    return ChatWire.image(fromURL: part["image_url"]?.stringValue ?? part["file_id"]?.stringValue ?? "")
                case "input_file":
                    return .text("[file omitted: \(part["filename"]?.stringValue ?? "file")]")
                default:
                    return nil
                }
            }
        case nil, .null?: return []
        default: throw APIError.invalid("\(path).content: must be a string or an array of parts")
        }
    }

    static func usage(_ u: RelayUsage) -> JSONValue {
        [
            "input_tokens": .int(u.promptTotal), "input_tokens_details": ["cached_tokens": .int(u.cacheRead)],
            "output_tokens": .int(u.output), "output_tokens_details": ["reasoning_tokens": 0],
            "total_tokens": .int(u.promptTotal + u.output),
        ]
    }
}

/// Builds the Responses output items from relay events; shared by the
/// streaming encoder and the non-streaming aggregator.
struct ResponsesBuilder {
    enum Open { case message, reasoning }
    let responseId: String
    let model: String
    let request: ChatRequest
    let createdAt = Int(Date().timeIntervalSince1970)
    private(set) var output: [JSONValue] = []
    private var open: Open?
    private var openId = ""
    private var openText = ""

    init(request: ChatRequest, responseId: String) {
        self.request = request
        self.responseId = responseId
        self.model = request.model
    }

    /// The response object (`status` in_progress, completed, incomplete or failed).
    func response(status: String, usage: RelayUsage? = nil, error: APIError? = nil) -> JSONValue {
        var r: [String: JSONValue] = [
            "id": .string(responseId), "object": "response", "created_at": .int(createdAt),
            "status": .string(status), "model": .string(model), "output": .array(output),
            "parallel_tool_calls": true, "tool_choice": "auto", "tools": [], "store": false,
            "error": .null, "incomplete_details": .null,
        ]
        if let usage { r["usage"] = ResponsesWire.usage(usage) }
        if status == "incomplete" { r["incomplete_details"] = ["reason": "max_output_tokens"] }
        if let error { r["error"] = ["code": .string(error.type), "message": .string(error.message)] }
        return .object(r)
    }

    /// Events for `event` as (type, payload) pairs, without sequence numbers.
    mutating func events(for event: RelayEvent) -> [(String, [String: JSONValue])] {
        var out: [(String, [String: JSONValue])] = []
        switch event {
        case .text(let t):
            if open != .message { out += closeOpen(); out += openMessage() }
            openText += t
            out.append(("response.output_text.delta", [
                "item_id": .string(openId), "output_index": .int(output.count), "content_index": 0, "delta": .string(t),
                "logprobs": [],
            ]))
        case .thinking(let t):
            if open != .reasoning { out += closeOpen(); out += openReasoning() }
            openText += t
            out.append(("response.reasoning_summary_text.delta", [
                "item_id": .string(openId), "output_index": .int(output.count), "summary_index": 0, "delta": .string(t),
            ]))
        case .toolUse(let callId, let name, let input):
            out += closeOpen()
            let index = output.count
            if request.tool(named: name)?.freeform == true {
                let id = randomId("ctc_")
                let text = input["input"]?.stringValue ?? input.compactString
                let item: JSONValue = ["type": "custom_tool_call", "id": .string(id), "call_id": .string(callId),
                                       "name": .string(name), "input": .string(text), "status": "completed"]
                out.append(("response.output_item.added", ["output_index": .int(index), "item": [
                    "type": "custom_tool_call", "id": .string(id), "call_id": .string(callId), "name": .string(name),
                    "input": "", "status": "in_progress"]]))
                out.append(("response.custom_tool_call_input.delta", ["item_id": .string(id), "output_index": .int(index), "delta": .string(text)]))
                out.append(("response.custom_tool_call_input.done", ["item_id": .string(id), "output_index": .int(index), "input": .string(text)]))
                output.append(item)
                out.append(("response.output_item.done", ["output_index": .int(index), "item": item]))
            } else {
                let id = randomId("fc_")
                let arguments = input.compactString
                let item: JSONValue = ["type": "function_call", "id": .string(id), "call_id": .string(callId),
                                       "name": .string(name), "arguments": .string(arguments), "status": "completed"]
                out.append(("response.output_item.added", ["output_index": .int(index), "item": [
                    "type": "function_call", "id": .string(id), "call_id": .string(callId), "name": .string(name),
                    "arguments": "", "status": "in_progress"]]))
                out.append(("response.function_call_arguments.delta", ["item_id": .string(id), "output_index": .int(index), "delta": .string(arguments)]))
                out.append(("response.function_call_arguments.done", ["item_id": .string(id), "output_index": .int(index), "arguments": .string(arguments)]))
                output.append(item)
                out.append(("response.output_item.done", ["output_index": .int(index), "item": item]))
            }
        case .finish:
            out += closeOpen()
        case .failure:
            out += closeOpen()
        }
        return out
    }

    private mutating func openMessage() -> [(String, [String: JSONValue])] {
        open = .message
        openId = randomId("msg_")
        openText = ""
        let index = output.count
        return [
            ("response.output_item.added", ["output_index": .int(index), "item": [
                "type": "message", "id": .string(openId), "status": "in_progress", "role": "assistant", "content": []]]),
            ("response.content_part.added", ["item_id": .string(openId), "output_index": .int(index), "content_index": 0,
                                             "part": ["type": "output_text", "text": "", "annotations": []]]),
        ]
    }

    private mutating func openReasoning() -> [(String, [String: JSONValue])] {
        open = .reasoning
        openId = randomId("rs_")
        openText = ""
        let index = output.count
        return [
            ("response.output_item.added", ["output_index": .int(index), "item": ["type": "reasoning", "id": .string(openId), "summary": []]]),
            ("response.reasoning_summary_part.added", ["item_id": .string(openId), "output_index": .int(index), "summary_index": 0,
                                                       "part": ["type": "summary_text", "text": ""]]),
        ]
    }

    private mutating func closeOpen() -> [(String, [String: JSONValue])] {
        guard let kind = open else { return [] }
        open = nil
        let index = output.count
        switch kind {
        case .message:
            let part: JSONValue = ["type": "output_text", "text": .string(openText), "annotations": []]
            let item: JSONValue = ["type": "message", "id": .string(openId), "status": "completed", "role": "assistant", "content": [part]]
            output.append(item)
            return [
                ("response.output_text.done", ["item_id": .string(openId), "output_index": .int(index), "content_index": 0,
                                               "text": .string(openText), "logprobs": []]),
                ("response.content_part.done", ["item_id": .string(openId), "output_index": .int(index), "content_index": 0, "part": part]),
                ("response.output_item.done", ["output_index": .int(index), "item": item]),
            ]
        case .reasoning:
            let part: JSONValue = ["type": "summary_text", "text": .string(openText)]
            let item: JSONValue = ["type": "reasoning", "id": .string(openId), "summary": [part]]
            output.append(item)
            return [
                ("response.reasoning_summary_text.done", ["item_id": .string(openId), "output_index": .int(index), "summary_index": 0,
                                                          "text": .string(openText)]),
                ("response.reasoning_summary_part.done", ["item_id": .string(openId), "output_index": .int(index), "summary_index": 0, "part": part]),
                ("response.output_item.done", ["output_index": .int(index), "item": item]),
            ]
        }
    }
}

/// Responses SSE: typed events with increasing `sequence_number`.
struct ResponsesEncoder: WireEncoder {
    private var builder: ResponsesBuilder
    private var sequence = 0
    private var started = false

    init(request: ChatRequest, responseId: String) {
        builder = ResponsesBuilder(request: request, responseId: responseId)
    }

    private mutating func emit(_ type: String, _ payload: [String: JSONValue]) -> String {
        var body = payload
        body["type"] = .string(type)
        body["sequence_number"] = .int(sequence)
        sequence += 1
        return frame(type, .object(body))
    }

    mutating func frames(for event: RelayEvent) -> [String] {
        var out: [String] = []
        if !started {
            started = true
            out.append(emit("response.created", ["response": builder.response(status: "in_progress")]))
            out.append(emit("response.in_progress", ["response": builder.response(status: "in_progress")]))
        }
        for (type, payload) in builder.events(for: event) {
            out.append(emit(type, payload))
        }
        switch event {
        case .finish(let stop, let usage):
            let status = stop == "max_tokens" ? "incomplete" : "completed"
            out.append(emit(status == "completed" ? "response.completed" : "response.incomplete",
                            ["response": builder.response(status: status, usage: usage)]))
        case .failure(let error):
            out.append(emit("response.failed", ["response": builder.response(status: "failed", error: error)]))
        default:
            break
        }
        return out
    }

    mutating func close() -> [String] { [] }

    var ping: String { ": keep-alive\n\n" }
}

/// Responses non-streaming body.
struct ResponsesAggregator: WireAggregator {
    private var builder: ResponsesBuilder
    private var status = "in_progress"
    private var usage = RelayUsage()

    init(request: ChatRequest, responseId: String) {
        builder = ResponsesBuilder(request: request, responseId: responseId)
    }

    mutating func add(_ event: RelayEvent) {
        _ = builder.events(for: event)
        if case .finish(let stop, let u) = event {
            status = stop == "max_tokens" ? "incomplete" : "completed"
            usage = u
        }
    }

    var body: JSONValue {
        var r = builder.response(status: status, usage: usage).objectValue ?? [:]
        // The convenience field SDKs read.
        let text = (r["output"]?.arrayValue ?? []).compactMap { item -> String? in
            guard item["type"] == "message" else { return nil }
            return item["content"]?.arrayValue?.compactMap { $0["text"]?.stringValue }.joined()
        }.joined()
        r["output_text"] = .string(text)
        return .object(r)
    }
}
