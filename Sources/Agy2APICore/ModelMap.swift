import Foundation

/// Maps the model names clients send to agy model slugs.
///
/// Claude Code asks for `claude-opus-5-5`, `claude-haiku-…`; Codex for
/// `gpt-5.5`; agy names its models `claude-opus-5-5-high`,
/// `gemini-4-neon-medium`. Resolution, first match wins:
///   1. an alias from `models.json` (exact, then `*` globs), case-insensitive;
///   2. an agy slug as is (with or without `agy/`);
///   3. the agy family: vendor prefix and date suffix dropped, `5.5` read as
///      `5-5`, then the variant for the request's effort (default `high`);
///   4. a small-model name (haiku, mini, flash, nano…) → the fast model;
///   5. the default model.
public struct ModelMap: Sendable, Codable {
    /// Client name (or `*` glob) → agy slug.
    public var aliases: [String: String] = [:]
    public var defaultModel: String = "gemini-4-neon-high"
    public var fastModel: String = "gemini-3.8-flash-low"
    /// Effort variant used when a request names a family without one.
    public var defaultEffort: String = "high"

    public init() {}

    enum CodingKeys: String, CodingKey { case aliases, defaultModel = "default", fastModel = "fast", defaultEffort = "effort" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        aliases = try c.decodeIfPresent([String: String].self, forKey: .aliases) ?? [:]
        defaultModel = try c.decodeIfPresent(String.self, forKey: .defaultModel) ?? "gemini-4-neon-high"
        fastModel = try c.decodeIfPresent(String.self, forKey: .fastModel) ?? "gemini-3.8-flash-low"
        defaultEffort = try c.decodeIfPresent(String.self, forKey: .defaultEffort) ?? "high"
    }

    // MARK: - Storage

    static func file(_ config: ServiceConfig) -> URL {
        config.root.appendingPathComponent("models.json")
    }

    public static func load(_ config: ServiceConfig) -> ModelMap {
        guard let data = try? Data(contentsOf: file(config)),
              let map = try? JSONDecoder().decode(ModelMap.self, from: data) else { return ModelMap() }
        return map
    }

    public func save(_ config: ServiceConfig) throws {
        try FileManager.default.createDirectory(at: config.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.file(config), options: .atomic)
    }

    // MARK: - Resolution

    /// The agy slug for `requested`, given the slugs agy offers and the
    /// effort the request asked for (`low`, `medium`, `high`, `xhigh`, `max`).
    public func resolve(_ requested: String, available: Set<String>, effort: String? = nil) -> (slug: String, rule: String) {
        let name = requested.trimmingCharacters(in: .whitespaces)
        let lower = name.lowercased()

        if let target = aliases.first(where: { $0.key.lowercased() == lower })?.value {
            return (Self.variant(of: target, available: available, effort: effort ?? defaultEffort), "alias \(name) → \(target)")
        }
        if let (pattern, target) = aliases.filter({ $0.key.contains("*") }).sorted(by: { $0.key.count > $1.key.count })
            .first(where: { Self.glob($0.key.lowercased(), matches: lower) }) {
            return (Self.variant(of: target, available: available, effort: effort ?? defaultEffort), "alias \(pattern) → \(target)")
        }

        let bare = lower.hasPrefix("agy/") ? String(lower.dropFirst(4)) : lower
        if available.contains(bare) { return (bare, "agy model") }

        let family = Self.family(of: bare)
        if available.contains(family) { return (family, "agy model") }
        let variants = Self.efforts(for: effort ?? defaultEffort)
        for variant in variants where available.contains("\(family)-\(variant)") {
            return ("\(family)-\(variant)", "family \(family)")
        }
        // A family agy has under another effort only.
        if let any = available.filter({ $0.hasPrefix(family + "-") }).sorted().first {
            return (any, "family \(family)")
        }

        if ["haiku", "mini", "flash", "nano", "small", "lite", "fast"].contains(where: bare.contains) {
            return (fastModel, "fast model")
        }
        return (defaultModel, "default model")
    }

    /// An alias target as an agy slug: as is when agy has it, else its
    /// family's variant for `effort` (`gemini-4-neon` → `gemini-4-neon-high`).
    static func variant(of target: String, available: Set<String>, effort: String) -> String {
        let t = target.lowercased().hasPrefix("agy/") ? String(target.dropFirst(4)) : target
        if available.contains(t) { return t }
        let family = family(of: t.lowercased())
        for v in efforts(for: effort) where available.contains("\(family)-\(v)") { return "\(family)-\(v)" }
        return t
    }

    /// `anthropic/claude-opus-5.5-20260101` → `claude-opus-5-5`.
    static func family(of name: String) -> String {
        var s = name
        if let slash = s.lastIndex(of: "/") { s = String(s[s.index(after: slash)...]) }
        // Date suffixes: -20260101, -2026-01-01, @20260101.
        s = s.replacingOccurrences(of: #"[-@]\d{4}-?\d{2}-?\d{2}$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"-latest$"#, with: "", options: .regularExpression)
        // Version dots read as agy's hyphens: 5.5 → 5-5 (but not gemini-3.8).
        if s.hasPrefix("claude-") { s = s.replacingOccurrences(of: ".", with: "-") }
        // An effort the client already put in the name stays.
        return s
    }

    /// Variant suffixes to try for an effort, nearest first.
    static func efforts(for effort: String) -> [String] {
        switch effort.lowercased() {
        case "minimal", "low": return ["low", "medium", "high"]
        case "medium": return ["medium", "high", "low"]
        case "xhigh", "max": return ["xhigh", "high", "medium"]
        default: return ["high", "medium", "xhigh", "low"]
        }
    }

    static func glob(_ pattern: String, matches text: String) -> Bool {
        let regex = "^" + pattern.split(separator: "*", omittingEmptySubsequences: false)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: ".*") + "$"
        return text.range(of: regex, options: .regularExpression) != nil
    }
}
