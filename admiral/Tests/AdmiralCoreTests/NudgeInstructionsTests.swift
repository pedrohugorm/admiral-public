import XCTest
@testable import AdmiralCore

/// Nudges stay in a session's context until compaction, so they carry facts only, and how to
/// treat them is said once — the bridge MCP server's `instructions`, in the system prompt.
@MainActor
final class NudgeInstructionsTests: XCTestCase {
    /// The instructions have to reach claude, and `initialize` is the only reply that carries
    /// them. Lose this and the trimmed nudges arrive with no guidance at all.
    func testInitializeCarriesTheNudgeInstructions() throws {
        let manager = SessionManager(host: FakeTerminalHost(),
                                     claudeHome: URL(fileURLWithPath: "/tmp/admiral-none"),
                                     executablePath: "/bin/echo")
        let server = MCPServer(bridge: BridgeCore(manager: manager, idGenerator: { "id" }))
        let request = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#.utf8)
        let response = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: server.handle(requestData: request, sessionToken: "A")) as? [String: Any])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["instructions"] as? String, NudgeInstructions.text)
    }

    /// What each nudge used to repeat now lives in the instructions, once.
    func testInstructionsSayWhatTheNudgesNoLongerRepeat() {
        let text = NudgeInstructions.text
        for header in ["WATCHDOG CHECK", "GOALS CHECK", "PR WATCH"] {
            XCTAssertTrue(text.contains(header), header)
        }
        XCTAssertTrue(text.contains("continue it immediately after reporting"), text)
        XCTAssertTrue(text.contains("yours to land"), text)
        XCTAssertTrue(text.contains("restated to the user"), text)
    }

    func testPRWatchMessageIsFactsOnly() {
        let digest = PRDigest(number: 7, title: "fix it", url: "https://example.test/pr/7",
                              state: .blocked, checks: .running, approvals: 0)
        let text = PRWatchMessage.text(for: [PRChange(root: "/r/repo", digest: digest,
                                                      deltas: ["checks running"])])
        XCTAssertEqual(text, "PR WATCH — a pull request you are working on changed:\n"
                       + "repo #7 \"fix it\"\n  checks running\n  https://example.test/pr/7")
    }

    func testSeededWatchdogProbeDropsTheStandingInstruction() {
        XCTAssertEqual(WatchRule.seeded.probeTemplate,
                       "WATCHDOG CHECK — you were told: \"{trigger}\". Is that fully done "
                       + "(deployed AND validated in PROD)? Report via set_structured_output.")
    }

    func testGoalsProbeDropsTheStandingInstruction() throws {
        guard case let .success(goals) = SessionGoals.make(from: ["ship it"]) else {
            return XCTFail("fixture must be valid")
        }
        XCTAssertEqual(GoalsTemplate.probe(goals.outstanding),
                       "GOALS CHECK — these goals are still open: g1) ship it. Report which are "
                       + "now met via set_structured_output with `type` set to \"goals\" (one entry "
                       + "per goal id, with `done` true or false).")
    }
}
