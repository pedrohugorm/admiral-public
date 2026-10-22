import XCTest
import Combine
@testable import AdmiralCore

final class SessionGoalsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func make(_ texts: [String]) throws -> SessionGoals {
        switch SessionGoals.make(from: texts, now: t0) {
        case let .success(goals): return goals
        case let .failure(error): throw error
        }
    }
    private func error(_ texts: [String]) -> GoalError? {
        switch SessionGoals.make(from: texts) {
        case .success: return nil
        case let .failure(error): return error
        }
    }

    func testNumbersIdsAndKeepsOrder() throws {
        let goals = try make(["first", "second", "third"])
        XCTAssertEqual(goals.goals.map(\.id), ["g1", "g2", "g3"])
        XCTAssertEqual(goals.goals.map(\.text), ["first", "second", "third"])
        XCTAssertTrue(goals.goals.allSatisfy { !$0.done })
        XCTAssertEqual(goals.setAt, t0)
    }

    /// A goal is injected on one prompt line — a newline inside it would submit early.
    func testCollapsesNewlinesAndTrims() throws {
        let goals = try make(["  ship it\nthen verify\r  "])
        XCTAssertEqual(goals.goals.first?.text, "ship it then verify")
    }

    func testEmptyListIsValidAndMeansClear() throws {
        XCTAssertTrue(try make([]).isEmpty)
    }

    func testBoundaries() {
        XCTAssertNil(error([String(repeating: "x", count: 280)]), "280 is allowed")
        XCTAssertEqual(error([String(repeating: "x", count: 281)]),
                       .tooLong(index: 0, count: 281))
        XCTAssertNil(error((1...10).map { "goal \($0)" }), "10 is allowed")
        XCTAssertEqual(error((1...11).map { "goal \($0)" }), .tooMany(count: 11))
        XCTAssertEqual(error(["fine", "   "]), .blank(index: 1))
    }

    /// The length rule applies after normalization, so trailing whitespace never costs a goal.
    func testLengthIsMeasuredAfterNormalizing() {
        XCTAssertNil(error([String(repeating: "x", count: 280) + "   "]))
    }

    func testProgressAndOutstanding() throws {
        var goals = try make(["a", "b", "c"])
        goals.apply(statuses: ["g1": .met], now: t0)
        XCTAssertEqual(goals.progress.done, 1)
        XCTAssertEqual(goals.progress.total, 3)
        XCTAssertEqual(goals.outstanding.map(\.id), ["g2", "g3"])
        XCTAssertFalse(goals.isComplete)

        goals.apply(statuses: ["g2": .met, "g3": .met], now: t0)
        XCTAssertTrue(goals.isComplete)
    }

    func testApplyStampsCompletionAndCountsChanges() throws {
        var goals = try make(["a", "b"])
        XCTAssertEqual(goals.apply(statuses: ["g1": .met, "g2": .open], now: t0), 1)
        XCTAssertEqual(goals.goals[0].resolvedAt, t0)
        XCTAssertNil(goals.goals[1].resolvedAt)
        XCTAssertEqual(goals.apply(statuses: ["g1": .met], now: t0), 0, "already done")
    }

    /// A probe answer that arrives after the goals were replaced must not resurrect them.
    func testApplyIgnoresUnknownIds() throws {
        var goals = try make(["a"])
        XCTAssertEqual(goals.apply(statuses: ["g7": .met, "": .met], now: t0), 0)
        XCTAssertFalse(goals.goals[0].done)
    }

    func testReopeningAGoalClearsItsCompletion() throws {
        var goals = try make(["a"])
        goals.apply(statuses: ["g1": .met], now: t0)
        XCTAssertEqual(goals.apply(statuses: ["g1": .open], now: t0), 1)
        XCTAssertNil(goals.goals[0].resolvedAt)
    }
}

final class GoalsStoreTests: XCTestCase {
    private var store: GoalsStore!
    private var base: URL!

    override func setUp() {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("goals-store-\(UUID().uuidString)")
        store = GoalsStore(base: base)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: base) }

    private func goals(_ texts: [String]) -> SessionGoals {
        guard case let .success(goals) = SessionGoals.make(from: texts) else {
            fatalError("fixture must be valid")
        }
        return goals
    }

    /// The Footprint panel reads goals straight from the file, so nothing redraws it unless a
    /// write says so: a goal changed from the panel's menu while its session sits idle would
    /// never show. Every write publishes; a read does not.
    func testEveryWritePublishesAndReadsDoNot() {
        var published = 0
        let subscription = store.objectWillChange.sink { published += 1 }
        defer { subscription.cancel() }

        store.set(goals(["ship it", "verify in rnd"]), forSession: "sid")
        XCTAssertEqual(published, 1, "setting goals")
        store.update(forSession: "sid") { $0.apply(statuses: ["g1": .met]) }
        XCTAssertEqual(published, 2, "a status change")
        XCTAssertEqual(store.goals(forSession: "sid")?.progress.done, 1)
        XCTAssertEqual(published, 2, "reading changes nothing")
        store.set(nil, forSession: "sid")
        XCTAssertEqual(published, 3, "clearing")
    }

    func testRoundTripPerSession() {
        store.set(goals(["ship it"]), forSession: "sid-1")
        store.set(goals(["something else"]), forSession: "sid-2")
        XCTAssertEqual(store.goals(forSession: "sid-1")?.goals.map(\.text), ["ship it"])
        XCTAssertEqual(store.goals(forSession: "sid-2")?.goals.map(\.text), ["something else"])
        XCTAssertNil(store.goals(forSession: "sid-3"))
    }

    /// "No goals" has one representation, so the panel has one thing to check.
    func testEmptyAndNilBothRemoveTheEntry() {
        store.set(goals(["x"]), forSession: "sid")
        store.set(goals([]), forSession: "sid")
        XCTAssertNil(store.goals(forSession: "sid"))

        store.set(goals(["x"]), forSession: "sid")
        store.set(nil, forSession: "sid")
        XCTAssertNil(store.goals(forSession: "sid"))
    }

    func testUpdateMergesInPlaceAndIsANoOpWhenUnset() {
        store.set(goals(["a", "b"]), forSession: "sid")
        store.update(forSession: "sid") { $0.apply(statuses: ["g2": .met]) }
        XCTAssertEqual(store.goals(forSession: "sid")?.progress.done, 1)

        store.update(forSession: "ghost") { $0.apply(statuses: ["g1": .met]) }
        XCTAssertNil(store.goals(forSession: "ghost"))
    }
}

final class ChecklistOrderTests: XCTestCase {
    private func item(_ id: String, _ state: PlanItemState) -> PlanItem {
        PlanItem(id: id, title: id, state: state)
    }

    /// Met items sink; everything else keeps the order it was created in.
    func testCompletedSinkToTheBottom() {
        let items = [item("a", .completed), item("b", .inProgress),
                     item("c", .completed), item("d", .pending)]
        XCTAssertEqual(items.openFirst.map(\.id), ["b", "d", "a", "c"])
    }

    func testAllOpenOrAllDoneKeepTheirOrder() {
        let open = [item("a", .inProgress), item("b", .pending)]
        XCTAssertEqual(open.openFirst.map(\.id), ["a", "b"])
        let done = [item("a", .completed), item("b", .completed)]
        XCTAssertEqual(done.openFirst.map(\.id), ["a", "b"])
        XCTAssertTrue([PlanItem]().openFirst.isEmpty)
    }
}
