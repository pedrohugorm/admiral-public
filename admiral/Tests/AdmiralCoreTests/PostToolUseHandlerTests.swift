import XCTest
@testable import AdmiralCore

final class PostToolUseHandlerTests: XCTestCase {
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

    func testWriteInRepoAppendsEvent() throws {
        let fm = FileManager.default
        let repo = tmp("repo"); try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repo) }
        git(["init", "-q"], cwd: repo.path)
        git(["checkout", "-q", "-b", "feature/X"], cwd: repo.path)
        let support = tmp("support"); defer { try? fm.removeItem(at: support) }

        let file = repo.appendingPathComponent("a.txt").path
        let payload = Data("""
        {"tool_name":"Write","tool_input":{"file_path":"\(file)"},"cwd":"\(repo.path)"}
        """.utf8)
        PostToolUseHandler.handle(payload: payload, base: support, token: "t", now: { "TS" })

        let log = AdmiralPaths.touchedLog(base: support, token: "t")
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        let e = try JSONDecoder().decode(TouchedRepoEvent.self, from: Data(lines[0].utf8))
        XCTAssertEqual(URL(fileURLWithPath: e.repoRoot ?? "").resolvingSymlinksInPath().path,
                       repo.resolvingSymlinksInPath().path)
        XCTAssertEqual(e.branch, "feature/X")
        XCTAssertTrue(e.insideSessionRoot)
        XCTAssertEqual(e.tool, "Write")
    }

    func testWriteInOtherRepoIsOutsideRoot() throws {
        let fm = FileManager.default
        let sessionRepo = tmp("sess"); try fm.createDirectory(at: sessionRepo, withIntermediateDirectories: true)
        let otherRepo = tmp("other"); try fm.createDirectory(at: otherRepo, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: sessionRepo); try? fm.removeItem(at: otherRepo) }
        git(["init", "-q"], cwd: sessionRepo.path)
        git(["init", "-q"], cwd: otherRepo.path)
        let support = tmp("support"); defer { try? fm.removeItem(at: support) }

        let file = otherRepo.appendingPathComponent("z.txt").path
        let payload = Data("""
        {"tool_name":"Edit","tool_input":{"file_path":"\(file)"},"cwd":"\(sessionRepo.path)"}
        """.utf8)
        PostToolUseHandler.handle(payload: payload, base: support, token: "t", now: { "TS" })

        let log = AdmiralPaths.touchedLog(base: support, token: "t")
        let e = try JSONDecoder().decode(TouchedRepoEvent.self,
            from: Data(String(contentsOf: log, encoding: .utf8).split(separator: "\n")[0].utf8))
        XCTAssertFalse(e.insideSessionRoot)
    }

    func testNonWriteToolIgnored() throws {
        let support = tmp("support"); defer { try? FileManager.default.removeItem(at: support) }
        let payload = Data(#"{"tool_name":"Bash","tool_input":{"command":"ls"},"cwd":"/tmp"}"#.utf8)
        PostToolUseHandler.handle(payload: payload, base: support, token: "t")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: AdmiralPaths.touchedLog(base: support, token: "t").path))
    }

    func testNonGitPathRecordedWithNilRoot() throws {
        let fm = FileManager.default
        let dir = tmp("plain"); try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let support = tmp("support"); defer { try? fm.removeItem(at: support) }
        let file = dir.appendingPathComponent("x.txt").path
        let payload = Data("""
        {"tool_name":"Write","tool_input":{"file_path":"\(file)"},"cwd":"\(dir.path)"}
        """.utf8)
        PostToolUseHandler.handle(payload: payload, base: support, token: "t", now: { "TS" })
        let e = try JSONDecoder().decode(TouchedRepoEvent.self,
            from: Data(String(contentsOf: AdmiralPaths.touchedLog(base: support, token: "t"),
                              encoding: .utf8).split(separator: "\n")[0].utf8))
        XCTAssertNil(e.repoRoot)
    }

    func testNotebookEditUsesNotebookPath() throws {
        let fm = FileManager.default
        let repo = tmp("repo"); try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repo) }
        git(["init", "-q"], cwd: repo.path)
        git(["checkout", "-q", "-b", "nb"], cwd: repo.path)
        let support = tmp("support"); defer { try? fm.removeItem(at: support) }

        let nb = repo.appendingPathComponent("nb.ipynb").path
        let payload = Data("""
        {"tool_name":"NotebookEdit","tool_input":{"notebook_path":"\(nb)"},"cwd":"\(repo.path)"}
        """.utf8)
        PostToolUseHandler.handle(payload: payload, base: support, token: "t", now: { "TS" })

        let log = AdmiralPaths.touchedLog(base: support, token: "t")
        let e = try JSONDecoder().decode(TouchedRepoEvent.self,
            from: Data(String(contentsOf: log, encoding: .utf8).split(separator: "\n")[0].utf8))
        XCTAssertEqual(e.tool, "NotebookEdit")
        XCTAssertTrue(e.filePath.hasSuffix("nb.ipynb"))
        XCTAssertEqual(URL(fileURLWithPath: e.repoRoot ?? "").resolvingSymlinksInPath().path,
                       repo.resolvingSymlinksInPath().path)
    }

    func testRelativeFilePathResolvedAgainstCwd() throws {
        let fm = FileManager.default
        let repo = tmp("repo"); try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repo) }
        git(["init", "-q"], cwd: repo.path)
        // The file's parent dir exists in practice (the write just created it); `git -C`
        // needs it to resolve the repo, so create `sub/` before invoking the handler.
        try fm.createDirectory(at: repo.appendingPathComponent("sub"), withIntermediateDirectories: true)
        let support = tmp("support"); defer { try? fm.removeItem(at: support) }

        let payload = Data("""
        {"tool_name":"Write","tool_input":{"file_path":"sub/x.txt"},"cwd":"\(repo.path)"}
        """.utf8)
        PostToolUseHandler.handle(payload: payload, base: support, token: "t", now: { "TS" })

        let log = AdmiralPaths.touchedLog(base: support, token: "t")
        let e = try JSONDecoder().decode(TouchedRepoEvent.self,
            from: Data(String(contentsOf: log, encoding: .utf8).split(separator: "\n")[0].utf8))
        XCTAssertEqual(e.filePath, repo.appendingPathComponent("sub/x.txt").path)
        XCTAssertTrue(e.insideSessionRoot)
    }
}
