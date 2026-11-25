import ArgumentParser
import Agy2APICore
import Foundation

@main
struct Agy2API: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agy2api",
        abstract: "Serve the Antigravity CLI (agy) as Anthropic Messages, OpenAI Chat Completions and OpenAI Responses.",
        version: Agy2APIVersion.current,
        subcommands: [Serve.self, Account.self, Key.self, Model.self],
        defaultSubcommand: Serve.self
    )
}

struct DataOptions: ParsableArguments {
    @Option(name: .long, help: "State directory (accounts, keys, models.json). Default: $AGY2API_HOME or ~/.agy2api")
    var dataRoot = ServiceConfig.defaultDataRoot

    @Option(name: .long, help: "agy executable.")
    var agy = ProcessInfo.processInfo.environment["AGY_PATH"] ?? "agy"

    var config: ServiceConfig {
        var config = ServiceConfig(dataRoot: (dataRoot as NSString).expandingTildeInPath)
        config.agyPath = agy
        return config
    }
}

func env(_ key: String) -> String? {
    ProcessInfo.processInfo.environment[key].flatMap { $0.isEmpty ? nil : $0 }
}

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run the API server.")

    @OptionGroup var data: DataOptions
    @Option(help: "Address to bind.") var host = env("AGY2API_HOST") ?? "127.0.0.1"
    @Option(help: "Port.") var port = Int(env("AGY2API_PORT") ?? "") ?? 8317
    @Flag(help: "Development: use this machine's own signed-in agy and require no API key.")
    var systemAccount = false

    func run() async throws {
        var config = data.config
        config.host = host
        config.port = port
        config.systemAccount = systemAccount
        if let v = env("AGY2API_TOOL_TIMEOUT").flatMap(TimeInterval.init) { config.toolResultTimeout = v }
        func mode(_ key: String) throws -> SystemPromptMode? {
            guard let v = env(key) else { return nil }
            guard let mode = SystemPromptMode(rawValue: v) else {
                throw ValidationError("\(key) must be keep, strip-identity or drop")
            }
            return mode
        }
        if let m = try mode("AGY2API_SYSTEM_PROMPT") { config.systemPromptMode = m }
        for (wire, suffix) in [(Wire.anthropic, "ANTHROPIC"), (.chat, "CHAT"), (.responses, "RESPONSES")] {
            if let m = try mode("AGY2API_SYSTEM_PROMPT_\(suffix)") { config.systemPromptModeByWire[wire] = m }
        }
        if let v = env("AGY2API_MAX_SESSIONS").flatMap(Int.init) { config.maxSessionsPerAccount = max(1, v) }
        if let v = env("AGY2API_SESSION_IDLE").flatMap(TimeInterval.init) { config.sessionIdleTimeout = v }
        if let v = env("AGY2API_ACCOUNT_IDLE").flatMap(TimeInterval.init) { config.accountIdleTimeout = v }

        let server = Agy2APIServer(config: config)
        let bound = try await server.start()
        let log = { (s: String) in FileHandle.standardError.write(Data((s + "\n").utf8)) }
        log("agy2api \(Agy2APIVersion.current) listening on http://\(host):\(bound)")
        if systemAccount {
            log("system account: using this machine's agy login; API keys are NOT checked")
        } else {
            let accounts = Accounts.list(config)
            log("accounts: \(accounts.isEmpty ? "none — run `agy2api account login <name>`" : accounts.joined(separator: ", "))")
            if KeyStore(config).entries().isEmpty { log("no API keys yet — run `agy2api key add <name>`") }
        }
        try await server.wait()
    }
}

// MARK: - account

struct Account: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage the agy accounts requests run on.",
        subcommands: [Login.self, List.self, Remove.self]
    )

    struct Login: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Sign an agy account in (prints a Google sign-in link).")
        @OptionGroup var data: DataOptions
        @Argument(help: "A name for the account.") var name: String

        func run() throws {
            guard Accounts.validName(name) else { throw ValidationError("use letters, digits, '-', '_' or '.'") }
            print("Signing in agy account '\(name)'. Open the link agy prints, sign in, then paste the code back here.")
            let status = try Accounts.login(data.config, name: name)
            guard status == 0, Accounts.list(data.config).contains(name) else {
                throw ValidationError("agy login did not complete (exit \(status))")
            }
            print("Account '\(name)' signed in\(Accounts.email(data.config, name: name).map { " as \($0)" } ?? "").")
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List signed-in accounts.")
        @OptionGroup var data: DataOptions
        func run() {
            let names = Accounts.list(data.config)
            if names.isEmpty { print("no accounts"); return }
            for name in names { print("\(name)\t\(Accounts.email(data.config, name: name) ?? "")") }
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove an account and its agy login.")
        @OptionGroup var data: DataOptions
        @Argument var name: String
        func run() throws {
            guard Accounts.validName(name) else { throw ValidationError("invalid name") }
            try Accounts.remove(data.config, name: name)
            print("removed \(name)")
        }
    }
}

// MARK: - key

struct Key: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage the API keys clients use.",
        subcommands: [Add.self, List.self, Remove.self]
    )

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a key (shown once).")
        @OptionGroup var data: DataOptions
        @Argument(help: "Who or what the key is for.") var name: String
        func run() throws {
            print(try KeyStore(data.config).add(name: name))
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List keys.")
        @OptionGroup var data: DataOptions
        func run() {
            let entries = KeyStore(data.config).entries()
            if entries.isEmpty { print("no keys"); return }
            for e in entries { print("\(e.name)\t\(e.hint)…\t\(ISO8601DateFormatter().string(from: e.created))") }
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Revoke a key.")
        @OptionGroup var data: DataOptions
        @Argument var name: String
        func run() throws {
            print(try KeyStore(data.config).remove(name: name) ? "revoked \(name)" : "no key named \(name)")
        }
    }
}

// MARK: - model

struct Model: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Map the model names clients send to agy models.",
        subcommands: [Map.self, Unmap.self, List.self, Default.self, Fast.self, Resolve.self]
    )

    struct Map: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Map a client model name (or a `*` glob) to an agy model.")
        @OptionGroup var data: DataOptions
        @Argument(help: "Name clients send, e.g. gpt-5.5 or 'claude-*'.") var name: String
        @Argument(help: "agy model, e.g. claude-opus-5-5-high.") var target: String
        func run() throws {
            var map = ModelMap.load(data.config)
            map.aliases[name] = target
            try map.save(data.config)
            print("\(name) → \(target)")
        }
    }

    struct Unmap: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove a mapping.")
        @OptionGroup var data: DataOptions
        @Argument var name: String
        func run() throws {
            var map = ModelMap.load(data.config)
            print(map.aliases.removeValue(forKey: name) == nil ? "no mapping for \(name)" : "unmapped \(name)")
            try map.save(data.config)
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show mappings and the default and fast models.")
        @OptionGroup var data: DataOptions
        func run() {
            let map = ModelMap.load(data.config)
            print("default\t\(map.defaultModel)\nfast\t\(map.fastModel)\neffort\t\(map.defaultEffort)")
            for (k, v) in map.aliases.sorted(by: { $0.key < $1.key }) { print("\(k)\t→ \(v)") }
        }
    }

    struct Default: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Set the model for names nothing else matches.")
        @OptionGroup var data: DataOptions
        @Argument var target: String
        func run() throws {
            var map = ModelMap.load(data.config)
            map.defaultModel = target
            try map.save(data.config)
            print("default → \(target)")
        }
    }

    struct Fast: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Set the model for small-model names (haiku, mini…).")
        @OptionGroup var data: DataOptions
        @Argument var target: String
        func run() throws {
            var map = ModelMap.load(data.config)
            map.fastModel = target
            try map.save(data.config)
            print("fast → \(target)")
        }
    }

    struct Resolve: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show which agy model a client name resolves to.")
        @OptionGroup var data: DataOptions
        @Argument var name: String
        @Option(help: "Reasoning effort the client sends.") var effort: String?
        func run() {
            let (slug, rule) = ModelMap.load(data.config).resolve(name, available: Agy2APIService.knownSlugs, effort: effort)
            print("\(name) → \(slug)  (\(rule))")
        }
    }
}
