import Foundation

/// What agy2api does with a client's system prompt before it reaches agy.
///
/// Coding-agent clients open their system prompt by naming themselves
/// ("You are Claude Code, …", "You are a Claude agent, built on …",
/// "You are Codex, …"), and Claude Code adds a billing header line. Those
/// lines describe the client, not the task, and agy's backend refuses a
/// session whose system prompt carries them (it answers RESOURCE_EXHAUSTED).
/// The default drops just those lines and keeps the instructions.
public enum SystemPromptMode: String, Sendable {
    /// Forward the client's system prompt unchanged.
    case keep
    /// Remove the client's self-identification and billing lines (default).
    case stripIdentity = "strip-identity"
    /// Send no client system prompt at all.
    case drop
}

enum SystemPromptFilter {
    /// Whole lines that are client metadata, not instructions.
    static let metadataLines = [
        #"(?im)^\s*x-anthropic-billing-header:.*$\n?"#,
    ]

    /// Self-identification sentences: "You are <client>…" up to the end of
    /// the sentence.
    static let identitySentences = [
        #"(?i)You are Claude Code\b[^.\n]*\.?"#,
        #"(?i)You are (?:a |an )?Claude agent\b[^.\n]*\.?"#,
        #"(?i)You are Codex\b[^.\n]*\.?"#,
        #"(?i)You are (?:an? )?(?:interactive )?(?:CLI|coding) (?:tool|agent) (?:made|built|developed) by (?:Anthropic|OpenAI)\b[^.\n]*\.?"#,
    ]

    static func apply(_ system: String?, mode: SystemPromptMode) -> String? {
        guard let system else { return nil }
        switch mode {
        case .keep:
            return system
        case .drop:
            return nil
        case .stripIdentity:
            var text = system
            for pattern in metadataLines + identitySentences {
                text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            }
            text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }
}
