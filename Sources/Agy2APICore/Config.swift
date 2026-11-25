import Foundation
import Crypto
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public struct ServiceConfig: Sendable {
    public var host = "127.0.0.1"
    public var port = 8317
    /// State: `accounts/<name>/home` (agy logins), `workspaces/`, `keys.json`.
    public var dataRoot: String
    public var agyPath = "agy"
    /// Development: one account, the machine's own signed-in agy, and no
    /// API keys required.
    public var systemAccount = false
    public var toolResultTimeout: TimeInterval = 15 * 60
    /// What happens to a client's system prompt (see `SystemPromptMode`),
    /// with per-wire overrides.
    public var systemPromptMode: SystemPromptMode = .stripIdentity
    public var systemPromptModeByWire: [Wire: SystemPromptMode] = [:]

    func systemPromptMode(for wire: Wire) -> SystemPromptMode {
        systemPromptModeByWire[wire] ?? systemPromptMode
    }
    public var maxSessionsPerAccount = 4
    public var sessionIdleTimeout: TimeInterval = 10 * 60
    public var accountIdleTimeout: TimeInterval = 30 * 60

    public init(dataRoot: String) {
        self.dataRoot = dataRoot
    }

    public static var defaultDataRoot: String {
        ProcessInfo.processInfo.environment["AGY2API_HOME"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".agy2api")
    }

    var root: URL { URL(fileURLWithPath: dataRoot, isDirectory: true) }
}

// MARK: - Accounts

/// The agy accounts signed in on this host, one HOME each.
public enum Accounts {
    static func directory(_ config: ServiceConfig) -> URL {
        config.root.appendingPathComponent("accounts", isDirectory: true)
    }

    public static func home(_ config: ServiceConfig, name: String) -> URL {
        directory(config).appendingPathComponent(name, isDirectory: true).appendingPathComponent("home", isDirectory: true)
    }

    static func credentialFile(home: URL) -> URL {
        home.appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token")
    }

    /// Names of accounts with an agy login.
    public static func list(_ config: ServiceConfig) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory(config).path)) ?? []
        return names.sorted().filter { FileManager.default.fileExists(atPath: credentialFile(home: home(config, name: $0)).path) }
    }

    /// The signed-in email of an account, if agy recorded one.
    public static func email(_ config: ServiceConfig, name: String) -> String? {
        guard let data = try? Data(contentsOf: credentialFile(home: home(config, name: name))),
              let json = try? JSONValue.decode(data) else { return nil }
        return json["id_token_email"]?.stringValue
    }

    public static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && name.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) } && !name.hasPrefix(".")
    }

    /// Run `agy acp --login` for `name` in this terminal: agy prints a Google
    /// sign-in link and reads the code back.
    public static func login(_ config: ServiceConfig, name: String) throws -> Int32 {
        let home = home(config, name: name)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let env = ProcessInfo.processInfo.environment
        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolveExecutable(config.agyPath, path: env["PATH"]))
        process.arguments = ["acp", "--login"]
        process.environment = ["HOME": home.path, "PATH": env["PATH"] ?? "/usr/bin:/bin", "LANG": env["LANG"] ?? "C.UTF-8",
                               "TERM": env["TERM"] ?? "xterm"]
        process.currentDirectoryURL = home
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    public static func remove(_ config: ServiceConfig, name: String) throws {
        try FileManager.default.removeItem(at: directory(config).appendingPathComponent(name, isDirectory: true))
    }

    static func resolveExecutable(_ name: String, path: String?) -> String {
        if name.contains("/") { return (name as NSString).expandingTildeInPath }
        let dirs = (path ?? "").split(separator: ":").map(String.init) + [NSHomeDirectory() + "/.local/bin", "/usr/local/bin"]
        for dir in dirs where FileManager.default.isExecutableFile(atPath: "\(dir)/\(name)") {
            return "\(dir)/\(name)"
        }
        return name
    }
}

// MARK: - API keys

/// API keys clients present (`Authorization: Bearer` or `x-api-key`).
/// Only SHA-256 hashes are stored, in `keys.json` (mode 0600).
public struct KeyStore: Sendable {
    public struct Entry: Codable, Sendable {
        public var name: String
        public var hash: String
        /// The first characters, to tell keys apart in listings.
        public var hint: String
        public var created: Date
    }

    let file: URL

    public init(_ config: ServiceConfig) {
        file = config.root.appendingPathComponent("keys.json")
    }

    public func entries() -> [Entry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Entry].self, from: data)) ?? []
    }

    func save(_ entries: [Entry]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let tmp = file.appendingPathExtension("tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: try encoder.encode(entries),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw APIError(status: 500, type: "api_error", message: "cannot write \(file.path)")
        }
        guard rename(tmp.path, file.path) == 0 else {
            throw APIError(status: 500, type: "api_error", message: "cannot replace \(file.path)")
        }
    }

    /// Create a key for `name`; the key itself is returned once and never stored.
    public func add(name: String) throws -> String {
        var generator = SystemRandomNumberGenerator()
        let raw = (0..<4).map { _ in String(format: "%016llx", generator.next() as UInt64) }.joined()
        let key = "sk-agy-" + raw
        var all = entries().filter { $0.name != name }
        all.append(Entry(name: name, hash: Self.hash(key), hint: String(key.prefix(14)), created: Date()))
        try save(all)
        return key
    }

    public func remove(name: String) throws -> Bool {
        let all = entries()
        let kept = all.filter { $0.name != name }
        try save(kept)
        return kept.count != all.count
    }

    /// The name of the key `presented` matches, if any.
    public func owner(of presented: String) -> String? {
        let digest = Self.hash(presented)
        return entries().first { Self.constantTimeEqual($0.hash, digest) }?.name
    }

    static func hash(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = UInt8(x.count == y.count ? 0 : 1)
        for i in 0..<max(x.count, y.count) { diff |= (i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0) }
        return diff == 0
    }
}
