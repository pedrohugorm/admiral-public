import XCTest
@testable import AdmiralCore

final class HookDispatcherTests: XCTestCase {
    private func tmp() -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("disp-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    func testUnknownPairIsNoOp() async {
        let base = tmp(); defer { try? FileManager.default.removeItem(at: base) }
        let out = await HookDispatcher.handle(
            cliType: "codex", event: "PostToolUse", payload: Data("{}".utf8), base: base, token: "t")
        XCTAssertNil(out)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: AdmiralPaths.touchedLog(base: base, token: "t").path))
    }

    func testUnknownEventIsNoOp() async {
        let base = tmp(); defer { try? FileManager.default.removeItem(at: base) }
        let out = await HookDispatcher.handle(
            cliType: "claude", event: "PreCompact", payload: Data("{}".utf8), base: base, token: "t")
        XCTAssertNil(out)
    }

    func testClaudePostToolUseRoutesToHandler() async {
        let base = tmp(); defer { try? FileManager.default.removeItem(at: base) }
        // A non-write tool is a no-op inside the handler, proving routing without needing git.
        let out = await HookDispatcher.handle(
            cliType: "claude", event: "PostToolUse",
            payload: Data(#"{"tool_name":"Bash","tool_input":{},"cwd":"/tmp"}"#.utf8),
            base: base, token: "t")
        XCTAssertNil(out)  // routed; PostToolUse returns no stdout
    }

    /// PostToolUse writes into `sessions/<token>/`, so it still needs `ADMIRAL_SESSION`.
    /// Without one there is nowhere to write, and the helper must do nothing at all.
    func testPostToolUseWithoutATokenIsANoOp() async {
        let base = tmp(); defer { try? FileManager.default.removeItem(at: base) }
        let payload = Data(#"{"tool_name":"Write","tool_input":{"file_path":"/tmp/x.txt"},"cwd":"/tmp"}"#.utf8)

        _ = await HookDispatcher.handle(
            cliType: "claude", event: "PostToolUse", payload: payload, base: base, token: nil)
        _ = await HookDispatcher.handle(
            cliType: "claude", event: "PostToolUse", payload: payload, base: base, token: "")

        let sessions = base.appendingPathComponent("sessions")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessions.path))
    }
}
