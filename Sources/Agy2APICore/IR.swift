import Foundation

// The shape every wire is parsed into and every reply is produced from.
// Anthropic Messages, OpenAI Chat Completions and OpenAI Responses differ in
// spelling, not in substance: turns of text, images, tool calls and tool
// results, plus a system prompt and a tool list.

public enum Wire: String, Sendable {
    case anthropic
    case chat
    case responses
}

public enum Role: String, Sendable, Hashable {
    case user
    case assistant
}

public enum Block: Sendable, Hashable {
    case text(String)
    case image(data: String, mimeType: String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseId: String, content: [Block], isError: Bool)
    /// Reasoning a client replays; never sent back to agy.
    case thinking(String)
}

public struct Turn: Sendable, Hashable {
    public var role: Role
    public var blocks: [Block]
    public init(role: Role, blocks: [Block]) {
        self.role = role
        self.blocks = blocks
    }
}

public struct ToolSpec: Sendable, Hashable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    /// A Responses `custom` tool: free-form text input instead of JSON.
    /// agy sees it as a tool taking one string, `input`.
    public var freeform: Bool

    public init(name: String, description: String, inputSchema: JSONValue, freeform: Bool = false) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.freeform = freeform
    }

    static let freeformSchema: JSONValue = [
        "type": "object",
        "properties": ["input": ["type": "string", "description": "The raw input for this tool."]],
        "required": ["input"],
    ]
}

/// A parsed request, whichever wire it came in on.
public struct ChatRequest: Sendable {
    public var wire: Wire
    /// The model id as the client sent it.
    public var model: String
    public var system: String?
    public var turns: [Turn]
    public var tools: [ToolSpec]
    public var stream: Bool
    /// Chat Completions `stream_options.include_usage`.
    public var includeUsage: Bool = false
    /// Responses `previous_response_id`.
    public var previousResponseId: String?
    /// Reasoning effort the client asked for (`low`, `medium`, `high`, …),
    /// used to pick a model variant.
    public var effort: String?
    /// The client's own id for the conversation, when it sends one (Claude
    /// Code `metadata.user_id`, Codex `prompt_cache_key`, Chat `user`), used
    /// to keep a conversation on one account.
    public var conversationKey: String?
    /// The agy model slug this request runs on (set by the service).
    public var slug: String = ""

    public init(wire: Wire, model: String, system: String?, turns: [Turn], tools: [ToolSpec], stream: Bool) {
        self.wire = wire
        self.model = model
        self.system = system
        self.turns = turns
        self.tools = tools
        self.stream = stream
    }

    func tool(named name: String) -> ToolSpec? {
        tools.first { $0.name == name }
    }
}

public struct RelayUsage: Sendable, Hashable {
    /// Uncached input tokens.
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    public var cacheWrite = 0
    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }
    public var promptTotal: Int { input + cacheRead + cacheWrite }
}

/// What a response streams, in order, independent of wire.
public enum RelayEvent: Sendable, Hashable {
    case text(String)
    case thinking(String)
    case toolUse(id: String, name: String, input: JSONValue)
    /// The response ends: `end_turn`, `tool_use`, `max_tokens` or `refusal`.
    case finish(stopReason: String, usage: RelayUsage)
    case failure(APIError)
}

/// An error with an HTTP status and an Anthropic-style error type; each wire
/// renders it in its own envelope.
public struct APIError: Error, Sendable, Hashable {
    public var status: Int
    public var type: String
    public var message: String

    public init(status: Int, type: String, message: String) {
        self.status = status
        self.type = type
        self.message = message
    }

    public static func invalid(_ message: String) -> APIError {
        APIError(status: 400, type: "invalid_request_error", message: message)
    }

    public static func auth(_ message: String) -> APIError {
        APIError(status: 401, type: "authentication_error", message: message)
    }

    public func body(for wire: Wire) -> JSONValue {
        switch wire {
        case .anthropic:
            return ["type": "error", "error": ["type": .string(type), "message": .string(message)]]
        case .chat, .responses:
            let code: String
            switch status {
            case 401: code = "invalid_api_key"
            case 404: code = "model_not_found"
            case 429: code = "rate_limit_exceeded"
            default: code = type
            }
            return ["error": ["message": .string(message), "type": .string(type), "param": nil, "code": .string(code)]]
        }
    }
}

/// Short random ids (hex), for message, call and item ids.
func randomId(_ prefix: String, length: Int = 24) -> String {
    prefix + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(length)
}
