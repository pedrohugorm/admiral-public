import XCTest
@testable import AdmiralCore

/// The per-session `settings.json` injected via `--settings`. It must stay hooks-only and
/// merge non-destructively: Claude Code overrides only the keys a settings file names, and
/// unions hooks across sources.
///
/// These are NOT governance hooks — governance is `hookd`, registered globally. Admiral
/// injects only the events its own features need, each with no other delivery path.
final class HookSettingsTests: XCTestCase {
    private let helper = "/X/admiral-hook"

    private func hooks() throws -> [String: Any] {
        let json = HookSettings.json(helper: helper)
        return try XCTUnwrap(json["hooks"] as? [String: Any])
    }

    /// The whole point of the removal: Admiral registers only the events feeding its own
    /// features — the touched-repos log, the structured-output tripwire, the watchdog's
    /// prompt log, the chat view, and the goals reminder's reset. Another entry here means
    /// governance crept back in.
    func testRegistersOnlyTheEventsAdmiralsOwnFeaturesNeed() throws {
        XCTAssertEqual(Set(try hooks().keys),
                       ["PostToolUse", "Stop", "UserPromptSubmit", "Notification", "PreToolUse",
                        "SessionStart"])
    }

    /// These Admiral used to govern and now has no use for — hookd owns them, and a stale
    /// entry here would spawn a helper per event for nothing.
    func testFormerlyGovernedEventsAreNotRegistered() throws {
        XCTAssertNil(try hooks()["SubagentStop"], "SubagentStop belongs to hookd now")
    }

    /// SessionStart is Admiral's again only to re-send the goals reminder once `/clear` or
    /// compaction has dropped it, so it is matched to those two sources: unmatched, every
    /// startup and resume would spawn a helper for nothing.
    func testSessionStartMatchesClearAndCompactOnly() throws {
        let entries = try XCTUnwrap(try hooks()["SessionStart"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0]["matcher"] as? String, "clear|compact")
    }

    func testNoEffectEventsAreNotRegistered() throws {
        for event in ["SessionEnd", "PreCompact"] {
            XCTAssertNil(try hooks()[event], event)
        }
    }

    /// PreToolUse exists only to keep the built-in AskUserQuestion out of a Chat-mode tab, so
    /// it is matched to that tool alone: unmatched, it would spawn a helper before EVERY tool
    /// call (and that is hookd's territory).
    func testPreToolUseMatchesAskUserQuestionOnly() throws {
        let entries = try XCTUnwrap(try hooks()["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0]["matcher"] as? String, "AskUserQuestion")
    }

    /// Every other event carries no matcher — one on PostToolUse would silently narrow what
    /// the touched-repos log ever sees.
    func testOtherEventsCarryNoMatcher() throws {
        for event in HookSettings.injectedEvents where !["PreToolUse", "SessionStart"].contains(event) {
            let entries = try XCTUnwrap(try hooks()[event] as? [[String: Any]], event)
            XCTAssertEqual(entries.count, 1, event)
            XCTAssertNil(entries[0]["matcher"], "\(event) must match all tools")
        }
    }

    func testEachEventInvokesTheHelperWithItsOwnEventName() throws {
        for event in HookSettings.injectedEvents {
            let entry = try XCTUnwrap((try hooks()[event] as? [[String: Any]])?.first)
            let command = try XCTUnwrap((entry["hooks"] as? [[String: Any]])?.first?["command"] as? String)
            XCTAssertEqual(command, "'\(helper)' claude \(event)")
        }
    }

    func testWrittenFileIsHooksOnly() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hs-\(UUID().uuidString)").appendingPathComponent("settings.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        XCTAssertTrue(HookSettings.write(helper: helper, to: url))

        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), ["hooks"], "never touch permissions or anything else")
    }

    /// A write failure must degrade to "no hook", never point claude at a missing file.
    func testWriteReturnsFalseWhenTheFileCannotBeCreated() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("hs-\(UUID().uuidString)")
        try "not a directory".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertFalse(HookSettings.write(helper: helper, to: file.appendingPathComponent("settings.json")))
    }
}
