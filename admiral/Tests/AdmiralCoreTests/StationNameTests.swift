import XCTest
@testable import AdmiralCore

/// Mirrors `tests/test_names.py` — the two fleets must not name the same thing differently.
final class StationNameTests: XCTestCase {
    func testSpacesBecomeHyphens() {
        XCTAssertEqual(StationName.sanitize("my session"), "my-session")
    }

    func testWhitespaceRunsCollapseToOneHyphen() {
        XCTAssertEqual(StationName.sanitize("a   b\tc"), "a-b-c")
    }

    func testSurroundingWhitespaceDoesNotBecomeHyphens() {
        XCTAssertEqual(StationName.sanitize("  padded  "), "padded")
    }

    /// Claude Code strips these when building the peer envelope's `from-name`; keeping
    /// them would make the tab title and the peer's prompt disagree.
    func testEnvelopeUnsafeCharactersAreDropped() {
        XCTAssertEqual(StationName.sanitize("a\"b<c>d"), "abcd")
    }

    func testNameIsCappedBeforeClaudeWouldEllipsizeIt() {
        XCTAssertEqual(StationName.sanitize(String(repeating: "x", count: 200)).count,
                       StationName.maxLength)
    }

    func testAlreadyCleanNameIsUnchanged() {
        XCTAssertEqual(StationName.sanitize("ADMIRAL-2"), "ADMIRAL-2")
    }

    func testUnderscoresTheUserTypedArePreserved() {
        XCTAssertEqual(StationName.sanitize("my_session"), "my_session")
    }

    func testBlankNameClears() {
        XCTAssertEqual(StationName.sanitize("   "), "")
    }

    func testNameOfOnlyUnsafeCharactersClears() {
        XCTAssertEqual(StationName.sanitize("<\">"), "")
    }

    func testApostrophesSurvive() {
        XCTAssertEqual(StationName.sanitize("Sam's tab"), "Sam's-tab")
    }
}
