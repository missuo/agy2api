import Foundation
import Testing
@testable import Agy2APICore

@Suite("Account scheduler")
struct SchedulerTests {
    let accounts = ["a", "b", "c"]

    @Test("round-robin places new conversations in turn and keeps each where it started")
    func roundRobinAndAffinity() async {
        let s = AccountScheduler(strategy: .roundRobin, cooldown: 600)
        var placed: [String] = []
        for i in 0..<4 {
            placed.append(await s.pick(conversation: "c\(i)", family: "gemini-4-neon", candidates: accounts, loads: [:])!)
        }
        #expect(placed == ["a", "b", "c", "a"])
        // The same conversation again (its session closed meanwhile): same account.
        #expect(await s.pick(conversation: "c1", family: "gemini-4-neon", candidates: accounts, loads: [:]) == "b")
        #expect(await s.pick(conversation: "c1", family: "claude-opus-5-5", candidates: accounts, loads: [:]) == "b")
    }

    @Test("least-sessions takes the lightest account")
    func leastSessions() async {
        let s = AccountScheduler(strategy: .leastSessions, cooldown: 600)
        #expect(await s.pick(conversation: "x", family: "f", candidates: accounts, loads: ["a": 3, "b": 1, "c": 2]) == "b")
    }

    @Test("a conversation moves off an account out of quota for its family, and only for that family")
    func quotaFailover() async {
        let s = AccountScheduler(strategy: .roundRobin, cooldown: 600)
        #expect(await s.pick(conversation: "x", family: "claude-opus-5-5", candidates: accounts, loads: [:]) == "a")
        await s.markExhausted("a", family: "claude-opus-5-5")
        let moved = await s.pick(conversation: "x", family: "claude-opus-5-5", candidates: accounts, loads: [:])
        #expect(moved != "a")
        // Now bound to the new account.
        #expect(await s.pick(conversation: "x", family: "claude-opus-5-5", candidates: accounts, loads: [:]) == moved)
        // Account a still serves other families.
        #expect(await s.isExhausted("a", family: "gemini-4-neon") == false)
    }

    @Test("cooldowns expire, and all-exhausted reports the wait")
    func cooldowns() async {
        let s = AccountScheduler(strategy: .roundRobin, cooldown: 600)
        let now = Date()
        for a in accounts { await s.markExhausted(a, family: "f", now: now) }
        let wait = await s.allExhausted(accounts, family: "f", now: now)
        #expect(wait != nil && abs(wait! - 600) < 1)
        #expect(await s.allExhausted(accounts, family: "g", now: now) == nil)
        #expect(await s.isExhausted("a", family: "f", now: now.addingTimeInterval(601)) == false)
    }

    @Test("quota families drop the effort suffix")
    func families() {
        #expect(AccountScheduler.family(of: "gemini-4-neon-high") == "gemini-4-neon")
        #expect(AccountScheduler.family(of: "claude-opus-5-5-xhigh") == "claude-opus-5-5")
        #expect(AccountScheduler.family(of: "gemini-pro-orchestrator") == "gemini-pro-orchestrator")
    }

    @Test("clients' own conversation ids are read from each wire")
    func conversationKeys() throws {
        let a = try AnthropicWire.parse(Data(#"{"model":"m","metadata":{"user_id":"user_1_session_abc"},"messages":[{"role":"user","content":"x"}]}"#.utf8))
        #expect(a.conversationKey == "user_1_session_abc")
        let r = try ResponsesWire.parse(Data(#"{"model":"m","prompt_cache_key":"conv-1","input":"x"}"#.utf8))
        #expect(r.conversationKey == "conv-1")
        let c = try ChatWire.parse(Data(#"{"model":"m","user":"u-9","messages":[{"role":"user","content":"x"}]}"#.utf8))
        #expect(c.conversationKey == "u-9")
    }
}
