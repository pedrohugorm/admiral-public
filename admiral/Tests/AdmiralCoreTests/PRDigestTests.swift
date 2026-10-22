import XCTest
@testable import AdmiralCore

final class PRDigestTests: XCTestCase {
    private func pr(merged: Bool = false, canMerge: Bool = false, approvals: Int = 0,
                    passed: Int = 0, running: Int = 0, failed: Int = 0) -> PRStatus {
        PRStatus(number: 920, title: "t", url: "u", isMerged: merged, canMerge: canMerge,
                 approvals: approvals, checksPassed: passed, checksRunning: running,
                 checksFailed: failed)
    }

    func testMergeStateCollapsesTheMergedCanMergePair() {
        XCTAssertEqual(PRState(pr(merged: true, canMerge: false)), .merged,
                       "merged wins even when the merge button is long gone")
        XCTAssertEqual(PRState(pr(canMerge: true)), .mergeable)
        XCTAssertEqual(PRState(pr(canMerge: false)), .blocked)
    }

    /// The worst news is the news: a suite with one failure reads as failed however many
    /// others passed, and a suite still running is not yet a pass.
    func testChecksPrecedenceIsFailedThenRunningThenPassed() {
        XCTAssertEqual(ChecksState(pr(passed: 9, running: 2, failed: 1)), .failed)
        XCTAssertEqual(ChecksState(pr(passed: 9, running: 2)), .running)
        XCTAssertEqual(ChecksState(pr(passed: 9)), .passed)
        XCTAssertEqual(ChecksState(pr()), .none)
    }

    /// The anti-spam rule: a CI run counts down (5 running → 4 → 3 …) and every one of those
    /// polls must produce the SAME signature, or the session gets a dozen injections per run.
    func testSignatureIgnoresCheckCountsAndTitleEdits() {
        let a = PRDigest(pr(passed: 1, running: 5))
        let b = PRDigest(pr(passed: 4, running: 2))
        XCTAssertEqual(a.signature, b.signature)

        var renamed = PRDigest(pr(canMerge: true))
        renamed.title = "a completely different title"
        renamed.url = "https://elsewhere"
        XCTAssertEqual(renamed.signature, PRDigest(pr(canMerge: true)).signature)
    }

    func testSignatureMovesOnStateChecksAndApprovals() {
        let base = PRDigest(pr(passed: 3))
        XCTAssertNotEqual(base.signature, PRDigest(pr(canMerge: true, passed: 3)).signature)
        XCTAssertNotEqual(base.signature, PRDigest(pr(passed: 3, failed: 1)).signature)
        XCTAssertNotEqual(base.signature, PRDigest(pr(approvals: 1, passed: 3)).signature)
    }

    func testDeltasNameBothSides() {
        let before = PRDigest(pr(canMerge: true, running: 2))
        let after = PRDigest(pr(approvals: 1, passed: 1, failed: 1))
        XCTAssertEqual(after.deltas(since: before),
                       ["blocked (was mergeable)", "checks FAILED (was checks running)",
                        "1 approval (was 0)"])
    }

    /// Nothing to compare against — the session gets the whole standing rather than a diff.
    func testDeltasWithNoPriorAnnouncementIsTheSummary() {
        let digest = PRDigest(pr(canMerge: true, approvals: 2, passed: 3))
        XCTAssertEqual(digest.deltas(since: nil), ["mergeable · checks passed · 2 approvals"])
    }
}
