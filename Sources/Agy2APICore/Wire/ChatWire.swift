import Foundation

/// OpenAI Chat Completions (`POST /v1/chat/completions`).
enum ChatWire {
    static func parse(_ body: Data) throws -> ChatRequest {
        guard let json = try? JSONValue.decode(body), case .object(let root) = json else {
            throw APIError.invalid("request body must be a JSON object")
        }
        guard let model = root["model"]?.stringValue, !model.isEmpty else { throw APIError.invalid("model: field required") }
        guard let messages = root["messages"]?.arrayValue, !messages.isEmpty else { throw APIError.invalid("messages: field required") }

        var system: [String] = []
        var turns: [Turn] = []
        func append(_ role: Role, _ blocks: [Block]) {
            guard !blocks.isEmpty else { return }
            if let last = turns.last, last.role == role {
                turns[turns.count - 1].blocks += blocks
            } else {
                turns.append(Turn(role: role, blocks: blocks))
            }
        }
        for (index, message) in messages.enumerated() {
            let path = "messages.\(index)"
            switch message["role"]?.stringValue {
            case "system", "developer":
                system.append(text(message["content"]))
            case "user":
                append(.user, try parts(message["content"], path: path))
            case "assistant":
                var blocks: [Block] = []
                if let reasoning = message["reasoning_content"]?.stringValue, !reasoning.isEmpty { blocks.append(.thinking(reasoning)) }
                let content = text(message["content"])
                if !content.isEmpty { blocks.append(.text(content)) }
                for call in message["tool_calls"]?.arrayValue ?? [] {
                    guard let id = call["id"]?.stringValue, let name = call["function"]?["name"]?.stringValue else {
                        throw APIError.invalid("\(path).tool_calls: each call needs id and function.name")
                    }
                    blocks.append(.toolUse(id: id, name: name, input: arguments(call["function"]?["arguments"])))
                }
                if blocks.isEmpty { blocks.append(.text("")) }
                append(.assistant, blocks)
            case "tool", "function":
                guard let id = message["tool_call_id"]?.stringValue ?? message["name"]?.stringValue else {
                    throw APIError.invalid("\(path).tool_call_id: field required")
                }
                append(.user, [.toolResult(toolUseId: id, content: [.text(text(message["content"]))], isError: false)])
            default:
                throw APIError.invalid("\(path).role: unsupported role \(message["role"]?.stringValue ?? "nil")")
            }
        }
        let tools = (root["tools"]?.arrayValue ?? []).compactMap { tool -> ToolSpec? in
            let fn = tool["function"] ?? tool
            guard let name = fn["name"]?.stringValue else { return nil }
            return ToolSpec(name: name, description: fn["description"]?.stringValue ?? "",
                            inputSchema: fn["parameters"] ?? ["type": "object", "properties": [:]])
        }
        var request = ChatRequest(wire: .chat, model: model, system: system.isEmpty ? nil : system.joined(separator: "\n\n"),
                                  turns: turns, tools: tools, stream: root["stream"]?.boolValue ?? false)
        request.includeUsage = root["stream_options"]?["include_usage"]?.boolValue ?? false
        request.effort = root["reasoning_effort"]?.stringValue
        return request
    }

    /// Plain text of a string or an array of text parts.
    static func text(_ content: JSONValue?) -> String {
        switch content {
        case .string(let s)?: return s
        case .array(let parts)?:
            return parts.compactMap { $0["text"]?.stringValue ?? ($0["type"] == nil ? $0.stringValue : nil) }.joined(separator: "\n")
        default: return ""
        }
    }

    static func parts(_ content: JSONValue?, path: String) throws -> [Block] {
        switch content {
        case .string(let s)?: return [.text(s)]
        case .array(let items)?:
            return items.compactMap { part -> Block? in
                switch part["type"]?.stringValue {
                case "text", "input_text": return .text(part["text"]?.stringValue ?? "")
                case "image_url":
                    let url = part["image_url"]?["url"]?.stringValue ?? part["image_url"]?.stringValue ?? ""
                    return image(fromURL: url)
                case "file":
                    return .text("[file omitted: \(part["file"]?["filename"]?.stringValue ?? "file")]")
                default: return nil
                }
            }
        case nil, .null?: return []
        default: throw APIError.invalid("\(path).content: must be a string or an array of parts")
        }
    }

    /// A `data:` URL becomes an inline image; a remote URL is named in text.
    static func image(fromURL url: String) -> Block {
        if url.hasPrefix("data:"), let comma = url.firstIndex(of: ",") {
            let header = url[url.index(url.startIndex, offsetBy: 5)..<comma]
            let mime = header.split(separator: ";").first.map(String.init) ?? "image/png"
            return .image(data: String(url[url.index(after: comma)...]), mimeType: mime)
        }
        return .text("[image: \(url)]")
    }

    /// Tool-call arguments arrive as a JSON string (or, from lax clients, an object).
    static func arguments(_ value: JSONValue?) -> JSONValue {
        switch value {
        case .string(let s)?: return (try? JSONValue.decode(Data(s.utf8))) ?? ["_raw": .string(s)]
        case .object?: return value!
        default: return .object([:])
        }
    }

    static func finishReason(_ stop: String) -> String {
        switch stop {
        case "tool_use": return "tool_calls"
        case "max_tokens": return "length"
        case "refusal": return "content_filter"
        default: return "stop"
        }
    }

    static func usage(_ u: RelayUsage) -> JSONValue {
        [
            "prompt_tokens": .int(u.promptTotal), "completion_tokens": .int(u.output),
            "total_tokens": .int(u.promptTotal + u.output),
            "prompt_tokens_details": ["cached_tokens": .int(u.cacheRead)],
        ]
    }
}

/// Chat Completions SSE (`data:` chunks, then `[DONE]`).
struct ChatEncoder: WireEncoder {
    let id = randomId("chatcmpl-")
    let model: String
    let includeUsage: Bool
    let created = Int(Date().timeIntervalSince1970)
    private var started = false
    private var toolIndex = 0

    init(request: ChatRequest) {
        model = request.model
        includeUsage = request.includeUsage
    }

    private func chunk(_ delta: JSONValue, finish: String? = nil) -> String {
        let body: JSONValue = [
            "id": .string(id), "object": "chat.completion.chunk", "created": .int(created), "model": .string(model),
            "choices": [["index": 0, "delta": delta, "finish_reason": finish.map { .string($0) } ?? .null]],
        ]
        return "data: \(body.compactString)\n\n"
    }

    mutating func frames(for event: RelayEvent) -> [String] {
        var out: [String] = []
        if !started, !isFailure(event) {
            started = true
            out.append(chunk(["role": "assistant", "content": ""]))
        }
        switch event {
        case .text(let t):
            out.append(chunk(["content": .string(t)]))
        case .thinking(let t):
            out.append(chunk(["reasoning_content": .string(t)]))
        case .toolUse(let id, let name, let input):
            out.append(chunk(["tool_calls": [[
                "index": .int(toolIndex), "id": .string(id), "type": "function",
                "function": ["name": .string(name), "arguments": .string(input.compactString)],
            ]]]))
            toolIndex += 1
        case .finish(let stop, let usage):
            out.append(chunk([:], finish: ChatWire.finishReason(stop)))
            if includeUsage {
                let body: JSONValue = [
                    "id": .string(id), "object": "chat.completion.chunk", "created": .int(created), "model": .string(model),
                    "choices": [], "usage": ChatWire.usage(usage),
                ]
                out.append("data: \(body.compactString)\n\n")
            }
        case .failure(let error):
            out.append("data: \(error.body(for: .chat).compactString)\n\n")
        }
        return out
    }

    private func isFailure(_ e: RelayEvent) -> Bool {
        if case .failure = e { return true }
        return false
    }

    mutating func close() -> [String] { ["data: [DONE]\n\n"] }

    var ping: String { ": keep-alive\n\n" }
}

/// Chat Completions non-streaming body.
struct ChatAggregator: WireAggregator {
    let id = randomId("chatcmpl-")
    let model: String
    private var text = ""
    private var reasoning = ""
    private var calls: [JSONValue] = []
    private var finish = "stop"
    private var usage = RelayUsage()

    init(request: ChatRequest) {
        model = request.model
    }

    mutating func add(_ event: RelayEvent) {
        switch event {
        case .text(let t): text += t
        case .thinking(let t): reasoning += t
        case .toolUse(let id, let name, let input):
            calls.append(["id": .string(id), "type": "function",
                          "function": ["name": .string(name), "arguments": .string(input.compactString)]])
        case .finish(let stop, let u): finish = ChatWire.finishReason(stop); usage = u
        case .failure: break
        }
    }

    var body: JSONValue {
        var message: [String: JSONValue] = ["role": "assistant", "content": text.isEmpty && !calls.isEmpty ? .null : .string(text)]
        if !calls.isEmpty { message["tool_calls"] = .array(calls) }
        if !reasoning.isEmpty { message["reasoning_content"] = .string(reasoning) }
        return [
            "id": .string(id), "object": "chat.completion", "created": .int(Int(Date().timeIntervalSince1970)),
            "model": .string(model),
            "choices": [["index": 0, "message": .object(message), "finish_reason": .string(finish)]],
            "usage": ChatWire.usage(usage),
        ]
    }
}
