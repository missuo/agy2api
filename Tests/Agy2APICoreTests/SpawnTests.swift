import Foundation
import Testing
@testable import Agy2APICore

@Suite("Accounts.spawnInForeground")
struct SpawnTests {
    @Test func runsInDirectoryWithEnvironmentAndReturnsExitCode() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let status = try Accounts.spawnInForeground(
            "/bin/sh", arguments: ["-c", "pwd -P > out; echo \"$MARK\" >> out; exit 7"],
            environment: ["MARK": "hello", "PATH": "/usr/bin:/bin"], directory: dir.path)
        #expect(status == 7)
        let lines = try String(contentsOf: dir.appendingPathComponent("out"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        let real = try #require(realpath(dir.path, nil))
        defer { free(real) }
        #expect(lines == [String(cString: real), "hello"])
    }

    @Test func staysInOurProcessGroup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try Accounts.spawnInForeground(
            "/bin/sh", arguments: ["-c", "ps -o pgid= -p $$ > pgid"],
            environment: ["PATH": "/usr/bin:/bin"], directory: dir.path)
        let child = try String(contentsOf: dir.appendingPathComponent("pgid"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(child == String(getpgrp()))
    }

    @Test func reportsSignalAs128Plus() throws {
        let status = try Accounts.spawnInForeground(
            "/bin/sh", arguments: ["-c", "kill -TERM $$"], environment: [:], directory: "/")
        #expect(status == 128 + SIGTERM)
    }

    @Test func throwsForMissingExecutable() {
        #expect(throws: (any Error).self) {
            try Accounts.spawnInForeground("/nonexistent/agy", arguments: [], environment: [:], directory: "/")
        }
    }
}
