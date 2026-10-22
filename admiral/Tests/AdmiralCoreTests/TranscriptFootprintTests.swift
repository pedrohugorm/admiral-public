import XCTest
@testable import AdmiralCore

final class TranscriptFootprintTests: XCTestCase {
    private func git(_ args: [String], cwd: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        p.environment = [
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null",
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin", "HOME": cwd,
        ]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
    }
    private func tmp(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
    }

    func testSeedsReposFromWriteToolCalls() throws {
        let fm = FileManager.default
        let repo = tmp("repo")
        try fm.createDirectory(at: repo.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repo) }
        git(["init", "-q"], cwd: repo.path)
        git(["checkout", "-q", "-b", "feature/z"], cwd: repo.path)

        let tx = tmp("tx").appendingPathExtension("jsonl")
        try fm.createDirectory(at: tx.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tx.deletingLastPathComponent()) }
        let lines = [
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"1","name":"Edit","input":{"file_path":"\#(repo.path)/sub/a.swift"}}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"2","name":"Write","input":{"file_path":"\#(repo.path)/b.swift"}}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"3","name":"NotebookEdit","input":{"notebook_path":"\#(repo.path)/n.ipynb"}}]}}"#,
            // A non-write tool — must be ignored.
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"4","name":"Bash","input":{"command":"ls"}}]}}"#,
            // A user line — must be ignored.
            #"{"type":"user","message":{"role":"user","content":"hi"}}"#,
        ]
        try lines.joined(separator: "\n").write(to: tx, atomically: true, encoding: .utf8)

        let repos = TranscriptFootprint.repos(transcriptPath: tx.path, cwd: repo.path)
        XCTAssertEqual(repos.count, 1)
        XCTAssertEqual(URL(fileURLWithPath: repos[0].root).resolvingSymlinksInPath().path,
                       repo.resolvingSymlinksInPath().path)
        XCTAssertEqual(repos[0].branches, ["feature/z"])
        XCTAssertTrue(repos[0].insideSessionRoot)
        XCTAssertEqual(repos[0].filesWritten, 3, "Edit + Write + NotebookEdit; Bash ignored")
    }

    func testMissingTranscriptReturnsEmpty() {
        XCTAssertEqual(
            TranscriptFootprint.repos(transcriptPath: "/nope/\(UUID().uuidString).jsonl", cwd: "/tmp"), [])
    }
}
