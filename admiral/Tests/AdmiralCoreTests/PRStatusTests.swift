import XCTest
@testable import AdmiralCore

final class PRStatusTests: XCTestCase {
    private func parse(_ json: String) -> PRStatus? {
        PRStatus.from(ghJSON: Data(json.utf8))
    }

    func testCleanOpenPRIsMergeableWithCountedApprovalsAndChecks() {
        let s = parse(#"""
        [{"number": 12, "state": "OPEN", "mergeStateStatus": "CLEAN", "title": "Add X", "url": "u",
          "latestReviews": [{"state": "APPROVED"}, {"state": "APPROVED"}, {"state": "COMMENTED"}],
          "statusCheckRollup": [
            {"__typename": "CheckRun", "status": "COMPLETED", "conclusion": "SUCCESS"},
            {"__typename": "CheckRun", "status": "IN_PROGRESS", "conclusion": ""},
            {"__typename": "StatusContext", "state": "FAILURE"}
          ]}]
        """#)
        XCTAssertEqual(s?.number, 12)
        XCTAssertTrue(s?.canMerge == true)
        XCTAssertEqual(s?.approvals, 2)
        XCTAssertEqual(s?.checksPassed, 1)
        XCTAssertEqual(s?.checksRunning, 1)
        XCTAssertEqual(s?.checksFailed, 1)
        XCTAssertFalse(s?.isMerged == true)
    }

    func testBlockedPRIsNotMergeable() {
        // mergeable conflict-free but missing required approvals → button not pressable.
        let s = parse(#"[{"number": 3, "state": "OPEN", "mergeStateStatus": "BLOCKED", "mergeable": "MERGEABLE", "title": "t", "url": "u"}]"#)
        XCTAssertEqual(s?.canMerge, false)
    }

    func testPrioritizesOpenOverMerged() {
        let s = parse(#"""
        [{"number": 5, "state": "MERGED", "mergeStateStatus": "UNKNOWN", "title": "old", "url": "u5"},
         {"number": 8, "state": "OPEN", "mergeStateStatus": "CLEAN", "title": "new", "url": "u8"}]
        """#)
        XCTAssertEqual(s?.number, 8)   // the OPEN one, not the merged
        XCTAssertEqual(s?.isMerged, false)
    }

    func testAllMergedShowsMergedAndPicksLatest() {
        let s = parse(#"""
        [{"number": 5, "state": "MERGED", "title": "a", "url": "u5"},
         {"number": 9, "state": "MERGED", "title": "b", "url": "u9"}]
        """#)
        XCTAssertEqual(s?.number, 9)
        XCTAssertEqual(s?.isMerged, true)
    }

    func testEmptyIsNil() {
        XCTAssertNil(parse("[]"))
    }

    func testClosedUnmergedOnlyIsNil() {
        // A `main` worktree only has old CLOSED merge-PRs → show nothing, not a stray chip.
        let s = parse(#"""
        [{"number": 692, "state": "CLOSED", "title": "merge main to dev", "url": "u"},
         {"number": 642, "state": "CLOSED", "title": "merge", "url": "u"}]
        """#)
        XCTAssertNil(s)
    }
}
