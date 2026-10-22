import XCTest
@testable import AdmiralCore

final class PRWatchMachineTests: XCTestCase {
    private let root = "/Users/x/repo"
    private let t0 = Date(timeIntervalSince1970: 3_000_000)

    private func digest(_ number: Int = 920, state: PRState = .blocked,
                        checks: ChecksState = .running, approvals: Int = 0) -> PRDigest {
        PRDigest(number: number, title: "fix the thing",
                 url: "https://github.com/x/repo/pull/\(number)",
                 state: state, checks: checks, approvals: approvals)
    }

    private func step(stored: PRWatchState?, _ digests: [PRDigest],
                      canType: Bool = true) -> PRWatchMachine.Result {
        PRWatchMachine.step(.init(stored: stored, fresh: [root: digests], canType: canType, now: t0))
    }

    private func text(_ result: PRWatchMachine.Result) -> String? {
        guard case let .inject(text) = result.effects.first else { return nil }
        return text
    }

    func testFirstSightingOfAnOpenPRAnnouncesItOnce() {
        let first = step(stored: nil, [digest()])
        XCTAssertEqual(first.effects.count, 1)
        XCTAssertTrue(text(first)?.contains("repo #920") == true, text(first) ?? "")

        let again = step(stored: first.state, [digest()])
        XCTAssertEqual(again.effects, [], "same signature, nothing to say")
    }

    /// The restart guard, stated as bytes: the state is written, read back the way the app
    /// reads it after a relaunch, and the very same poll must produce silence.
    func testStateRoundTrippedThroughDiskAnnouncesNothing() throws {
        let first = step(stored: nil, [digest()])
        XCTAssertEqual(first.effects.count, 1)

        let encoded = try JSONEncoder().encode(first.state)
        let reloaded = try JSONDecoder().decode(PRWatchState.self, from: encoded)
        XCTAssertEqual(step(stored: reloaded, [digest()]).effects, [],
                       "a relaunched Admiral must not re-announce what it already said")
    }

    /// A PR that was merged before anyone ever watched is history — that is what an old PR on
    /// `main` looks like on a session's first poll. Recorded, never announced.
    func testFirstSightingOfAMergedPRIsRecordedSilently() {
        let result = step(stored: nil, [digest(state: .merged, checks: .passed)])
        XCTAssertEqual(result.effects, [])
        XCTAssertNotNil(result.state.announced[PRWatchState.key(root: root, number: 920)],
                        "recorded, so it stays quiet forever after")
        XCTAssertEqual(result.state.repos[root]?.count, 1, "still reported by pr_status")
    }

    /// …but a merge that happens under a PR we already announced IS the news everyone wants.
    func testMergeOfAKnownPRIsAnnounced() {
        let seen = step(stored: nil, [digest()])
        let merged = step(stored: seen.state, [digest(state: .merged, checks: .passed)])
        XCTAssertTrue(text(merged)?.contains("merged (was blocked)") == true, text(merged) ?? "")
    }

    func testChecksAndApprovalsEachProduceALine() {
        let seen = step(stored: nil, [digest()])
        let failed = step(stored: seen.state, [digest(checks: .failed)])
        XCTAssertTrue(text(failed)?.contains("checks FAILED (was checks running)") == true)

        let approved = step(stored: failed.state, [digest(checks: .failed, approvals: 1)])
        XCTAssertTrue(text(approved)?.contains("1 approval (was 0)") == true)
    }

    /// Held (a dialog is open): `repos` still advances so `pr_status` is current, but nothing
    /// is marked as told — which is what makes the next cycle deliver it rather than lose it.
    func testHeldNewsKeepsPRStatusCurrentWithoutMarkingItTold() {
        let held = step(stored: nil, [digest()], canType: false)
        XCTAssertEqual(held.effects, [])
        XCTAssertEqual(held.state.repos[root]?.first?.checks, .running)
        XCTAssertTrue(held.state.announced.isEmpty)

        let delivered = step(stored: held.state, [digest(checks: .failed)])
        XCTAssertEqual(delivered.effects.count, 1)
        XCTAssertEqual(text(delivered)?.contains("was checks running"), false,
                       "it was never told about the running state, so it gets the standing")
    }

    /// Several PRs moving at once is one interruption, not three.
    func testChangesCoalesceIntoASingleInject() {
        let seen = step(stored: nil, [digest(920), digest(921)])
        XCTAssertEqual(seen.effects.count, 1)
        let both = text(seen) ?? ""
        XCTAssertTrue(both.contains("#920") && both.contains("#921"), both)
        XCTAssertTrue(both.contains("2 pull requests"), both)
    }

    /// A repo that was not polled this cycle keeps whatever was stored for it.
    func testUnpolledReposAreLeftAlone() {
        let seen = step(stored: nil, [digest()])
        let other = PRWatchMachine.step(.init(stored: seen.state, fresh: ["/other": []],
                                              canType: true, now: t0))
        XCTAssertEqual(other.state.repos[root]?.count, 1)
        XCTAssertEqual(other.effects, [])
    }

    func testSettledIsOnlyTrueWhenEveryKnownPRIsMerged() {
        var state = PRWatchState()
        state.repos[root] = [digest(920, state: .merged), digest(921, state: .blocked)]
        XCTAssertFalse(state.isSettled(root: root))
        state.repos[root] = [digest(920, state: .merged)]
        XCTAssertTrue(state.isSettled(root: root))
        XCTAssertFalse(PRWatchState().isSettled(root: root), "never polled is not settled")
    }
}
