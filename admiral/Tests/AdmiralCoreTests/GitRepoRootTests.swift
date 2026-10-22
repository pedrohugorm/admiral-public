import XCTest
@testable import AdmiralCore

final class GitRepoRootTests: XCTestCase {
    /// Run git with an isolated config/home so the test doesn't read the user's gitconfig.
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

    func testRepoRootFromSubdir() throws {
        let fm = FileManager.default
        let repo = fm.temporaryDirectory.appendingPathComponent("git-\(UUID().uuidString)")
        let sub = repo.appendingPathComponent("a/b")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repo) }
        git(["init", "-q"], cwd: repo.path)

        let root = try XCTUnwrap(Git.repoRoot(at: sub.path))
        XCTAssertEqual(URL(fileURLWithPath: root).resolvingSymlinksInPath().path,
                       repo.resolvingSymlinksInPath().path)
    }

    func testNonRepoReturnsNil() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("nogit-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        XCTAssertNil(Git.repoRoot(at: dir.path))
    }
}
