import Foundation

/// How a conversation with no account yet is given one.
public enum AccountStrategy: String, Sendable {
    /// Take the signed-in accounts in turn.
    case roundRobin = "round-robin"
    /// Take the account with the fewest live sessions.
    case leastSessions = "least-sessions"
}

/// Picks the agy account a conversation runs on.
///
/// A conversation keeps its account (affinity, for `affinityLifetime`) even
/// when its ACP session is closed and later reopened, so its history and
/// quota stay on one account. It moves only when that account has run out
/// of quota for the model's family (cooling down after a 429), or is gone.
/// Conversations without an account are placed by `strategy`.
actor AccountScheduler {
    let strategy: AccountStrategy
    let cooldown: TimeInterval
    static let affinityLifetime: TimeInterval = 24 * 60 * 60

    private var affinity: [String: (account: String, touched: Date)] = [:]
    /// "account\u{1}family" → when the account may be tried again.
    private var exhausted: [String: Date] = [:]
    private var cursor = 0

    init(strategy: AccountStrategy, cooldown: TimeInterval) {
        self.strategy = strategy
        self.cooldown = cooldown
    }

    /// The account for `conversation` among `candidates` (sorted names),
    /// for a model of quota `family`. `loads` are live sessions per account.
    /// Nil when there are no candidates.
    func pick(conversation: String, family: String, candidates: [String], loads: [String: Int], now: Date = Date()) -> String? {
        guard !candidates.isEmpty else { return nil }
        let healthy = candidates.filter { !isExhausted($0, family: family, now: now) }

        if let bound = affinity[conversation]?.account, healthy.contains(bound) {
            affinity[conversation]?.touched = now
            return bound
        }
        // Everyone is cooling down: try the one that recovers first.
        guard !healthy.isEmpty else {
            return candidates.min { (until($0, family) ?? now) < (until($1, family) ?? now) }
        }
        let chosen: String
        switch strategy {
        case .roundRobin:
            chosen = healthy[cursor % healthy.count]
            cursor += 1
        case .leastSessions:
            let fewest = healthy.map { loads[$0] ?? 0 }.min() ?? 0
            let tied = healthy.filter { (loads[$0] ?? 0) == fewest }
            chosen = tied[cursor % tied.count]
            cursor += 1
        }
        bind(conversation, to: chosen, now: now)
        return chosen
    }

    func bind(_ conversation: String, to account: String, now: Date = Date()) {
        affinity[conversation] = (account, now)
    }

    func boundAccount(_ conversation: String) -> String? {
        affinity[conversation]?.account
    }

    func markExhausted(_ account: String, family: String, now: Date = Date()) {
        exhausted["\(account)\u{1}\(family)"] = now.addingTimeInterval(cooldown)
    }

    func isExhausted(_ account: String, family: String, now: Date = Date()) -> Bool {
        guard let until = until(account, family) else { return false }
        return until > now
    }

    private func until(_ account: String, _ family: String) -> Date? {
        exhausted["\(account)\u{1}\(family)"]
    }

    /// Seconds until the first of `accounts` recovers when every one is
    /// cooling down for `family`; nil when any can be tried now.
    func allExhausted(_ accounts: [String], family: String, now: Date = Date()) -> TimeInterval? {
        guard !accounts.isEmpty else { return nil }
        var soonest: Date?
        for account in accounts {
            guard let until = until(account, family), until > now else { return nil }
            soonest = min(soonest ?? until, until)
        }
        return soonest.map { $0.timeIntervalSince(now) }
    }

    /// Forget affinities unused for a day and expired cooldowns.
    func prune(now: Date = Date()) {
        affinity = affinity.filter { now.timeIntervalSince($0.value.touched) < Self.affinityLifetime }
        exhausted = exhausted.filter { $0.value > now }
    }

    /// The quota family of an agy slug: the model without its effort
    /// (`gemini-4-neon-high` → `gemini-4-neon`); variants share a quota.
    static func family(of slug: String) -> String {
        slug.replacingOccurrences(of: #"-(low|medium|high|xhigh)$"#, with: "", options: .regularExpression)
    }
}
