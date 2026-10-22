import XCTest
@testable import AdmiralCore

/// The SessionManager side of a scheduled run: the tab it opens is named after the schedule,
/// carries the schema before its first prompt, and can be found and closed by name.
@MainActor
final class ScheduleBackendTests: XCTestCase {
    private var base: URL!
    private var manager: SessionManager!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("schedule-backend-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        manager = SessionManager(host: FakeTerminalHost(), claudeHome: base.appendingPathComponent("claude"),
                                 executablePath: "/bin/echo", supportDir: base)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: base) }

    func testARunTabIsANewScratchTabNamedAfterTheSchedule() throws {
        let tab = try manager.openRunTab(name: "nightly", cwd: base.path, scratch: true, provider: nil,
                                         model: "opus", effort: nil, outputSchema: nil).get()
        let session = try XCTUnwrap(manager.sessions.first { $0.id == tab.id })
        XCTAssertEqual(session.displayTitle, "nightly")
        XCTAssertTrue(session.scratch)
        XCTAssertEqual(session.cwd, base.path)
        XCTAssertEqual(tab.sessionID, session.claudeSessionID)
        XCTAssertEqual(manager.tabs(named: "nightly").map(\.id), [tab.id])
    }

    func testTheSchemaIsSetBeforeTheFirstPrompt() throws {
        let schema = JSONValue.object(["type": .string("object"), "properties": .object([:]),
                                       "required": .array([]), "additionalProperties": .bool(false)])
        let tab = try manager.openRunTab(name: "nightly", cwd: base.path, scratch: true, provider: nil,
                                         model: nil, effort: nil, outputSchema: schema).get()
        XCTAssertEqual(OutputSchemaStore.schema(base: base, session: try XCTUnwrap(tab.sessionID)), schema)
    }

    func testAnUnknownProviderOpensNothing() {
        XCTAssertThrowsError(try manager.openRunTab(name: "nightly", cwd: base.path, scratch: true,
                                                    provider: "no-such-provider-\(UUID())", model: nil,
                                                    effort: nil, outputSchema: nil).get())
        XCTAssertEqual(manager.sessions.count, 0)
    }

    /// The model a run names rides its tab's claude invocation as `--model`/`--effort`.
    func testARunCarriesItsModelAndEffortToTheClaudeInvocation() throws {
        let host = FakeTerminalHost()
        let manager = SessionManager(host: host, claudeHome: base.appendingPathComponent("claude"),
                                     executablePath: "/bin/zsh",
                                     defaultAgentType: .claudeZshRecipe(options: LaunchOptions()))
        _ = try manager.openRunTab(name: "nightly", cwd: base.path, scratch: true, provider: nil,
                                   model: "haiku", effort: "high", outputSchema: nil).get()
        let line = try XCTUnwrap(host.spawned.first?.args.last)
        XCTAssertTrue(line.contains("--session-id"), line)
        XCTAssertTrue(line.contains("--model haiku"), line)
        XCTAssertTrue(line.contains("--effort high"), line)
    }

    func testClosingATabRemovesIt() throws {
        let tab = try manager.openRunTab(name: "nightly", cwd: base.path, scratch: true, provider: nil,
                                         model: nil, effort: nil, outputSchema: nil).get()
        manager.closeTab(tab.id)
        XCTAssertEqual(manager.tabs(named: "nightly"), [])
    }
}
