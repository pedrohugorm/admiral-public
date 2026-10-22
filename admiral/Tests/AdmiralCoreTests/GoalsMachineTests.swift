import XCTest
@testable import AdmiralCore

final class GoalsMachineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 3_000_000)

    private func goals(_ texts: [String], done: [String] = []) -> SessionGoals {
        guard case var .success(goals) = SessionGoals.make(from: texts, now: now) else {
            fatalError("fixture must be valid")
        }
        goals.apply(statuses: Dictionary(uniqueKeysWithValues: done.map { ($0, GoalStatus.met) }), now: now)
        return goals
    }

    private func tick(_ goals: SessionGoals?, idle: TimeInterval = 0,
                      tripwire: GoalsMachine.TripwireView = .none,
                      enabled: Bool = true, at: TimeInterval = 0) -> GoalsMachine.Tick {
        GoalsMachine.Tick(config: GoalsNudgeConfig(enabled: enabled), goals: goals,
                          idleSeconds: idle, tripwire: tripwire,
                          now: now.addingTimeInterval(at))
    }

    private var watching: GoalsWatchState { GoalsWatchState(phase: .watching) }
    private func probing(at: TimeInterval = 0) -> GoalsWatchState {
        GoalsWatchState(phase: .probing, lastProbeAt: now.addingTimeInterval(at))
    }

    func testNoGoalsStaysIdle() {
        let r = GoalsMachine.step(state: GoalsWatchState(), tick: tick(nil, idle: 60 * 60))
        XCTAssertEqual(r.state.phase, .idle)
        XCTAssertTrue(r.effects.isEmpty)
    }

    func testGoalsStartWatching() {
        let r = GoalsMachine.step(state: GoalsWatchState(), tick: tick(goals(["ship it"])))
        XCTAssertEqual(r.state.phase, .watching)
        XCTAssertTrue(r.effects.isEmpty)
    }

    func testAllGoalsDoneStopsWatching() {
        let r = GoalsMachine.step(state: watching,
                                  tick: tick(goals(["ship it"], done: ["g1"]), idle: 60 * 60))
        XCTAssertEqual(r.state.phase, .idle)
        XCTAssertTrue(r.effects.isEmpty)
    }

    func testIdleBelowThresholdWaits() {
        let r = GoalsMachine.step(state: watching, tick: tick(goals(["a"]), idle: 4 * 60))
        XCTAssertEqual(r.state.phase, .watching)
        XCTAssertTrue(r.effects.isEmpty)
    }

    func testIdleOverThresholdProbesWithTheGoalsSchema() {
        let r = GoalsMachine.step(state: watching,
                                  tick: tick(goals(["ship it", "verify"], done: ["g1"]),
                                             idle: 5 * 60))
        XCTAssertEqual(r.state.phase, .probing)
        XCTAssertEqual(r.state.lastProbeAt, now)
        guard case let .armProbe(schema, text)? = r.effects.first, r.effects.count == 1 else {
            return XCTFail("expected exactly [armProbe], got \(r.effects)")
        }
        XCTAssertEqual(schema, GoalsMachine.probeSchemaJSON)
        XCTAssertTrue(text.contains("GOALS CHECK"), text)
        XCTAssertTrue(text.contains("g2) verify"), text)
        XCTAssertFalse(text.contains("ship it"), "a met goal is not still open")
    }

    /// The probe's answer is the only thing that marks a goal done.
    func testPartialAnswerMergesAndNagsWithWhatIsLeft() {
        let r = GoalsMachine.step(state: probing(),
                                  tick: tick(goals(["a", "b"]),
                                             tripwire: .fulfilled(completions: ["g1": true])))
        XCTAssertEqual(r.state.phase, .watching)
        XCTAssertEqual(r.state.cycles, 1)
        XCTAssertEqual(r.effects.first, .applyCompletions(["g1": true]))
        XCTAssertTrue(r.effects.contains(.clearTripwire))
        guard case let .injectNag(text)? = r.effects.last else {
            return XCTFail("expected a nag, got \(r.effects)")
        }
        XCTAssertTrue(text.contains("g2) b"), text)
        XCTAssertFalse(text.contains("g1"), "the goal it just finished is not nagged about")
    }

    func testCompletingEveryGoalNotifiesAndStandsDown() {
        let r = GoalsMachine.step(
            state: probing(),
            tick: tick(goals(["a", "b"]),
                       tripwire: .fulfilled(completions: ["g1": true, "g2": true])))
        XCTAssertEqual(r.state.phase, .idle)
        XCTAssertEqual(r.effects, [.applyCompletions(["g1": true, "g2": true]),
                                   .clearTripwire, .notifyAllDone])
    }

    func testProbeTimeoutNags() {
        let waited = tick(goals(["a"]), tripwire: .armedOurs, at: 3 * 60)
        let r = GoalsMachine.step(state: probing(), tick: waited)
        XCTAssertEqual(r.state.phase, .watching)
        XCTAssertEqual(r.effects.count, 2)
        XCTAssertEqual(r.effects.first, .clearTripwire)
    }

    func testProbeStillWithinTimeoutWaits() {
        let r = GoalsMachine.step(state: probing(),
                                  tick: tick(goals(["a"]), tripwire: .armedOurs, at: 2 * 60))
        XCTAssertEqual(r.state.phase, .probing)
        XCTAssertTrue(r.effects.isEmpty)
    }

    /// Stonewalling the schema is not escape — the same discipline the watchdog applies.
    func testFailedTripwireNags() {
        let r = GoalsMachine.step(state: probing(), tick: tick(goals(["a"]), tripwire: .failed))
        XCTAssertEqual(r.state.phase, .watching)
        XCTAssertTrue(r.effects.contains(.clearTripwire))
        XCTAssertEqual(r.effects.count, 2)
    }

    func testVanishedTripwireNagsWithoutClearing() {
        let r = GoalsMachine.step(state: probing(), tick: tick(goals(["a"]), tripwire: .none))
        XCTAssertEqual(r.state.phase, .watching)
        XCTAssertEqual(r.effects.count, 1, "nothing to clear — it is already gone")
        guard case .injectNag = r.effects[0] else { return XCTFail("expected a nag") }
    }

    func testDisablingMidProbeReleasesTheSlot() {
        let r = GoalsMachine.step(state: probing(),
                                  tick: tick(goals(["a"]), tripwire: .armedOurs, enabled: false))
        XCTAssertEqual(r.state.phase, .idle)
        XCTAssertEqual(r.effects, [.clearTripwire])
    }

    func testDisabledWithNothingArmedIsSilent() {
        let r = GoalsMachine.step(state: watching, tick: tick(goals(["a"]), enabled: false))
        XCTAssertEqual(r.state.phase, .idle)
        XCTAssertTrue(r.effects.isEmpty)
    }

    /// A stale answer naming goals that were replaced must not "complete" the new list.
    func testAnswerForUnknownIdsNagsRatherThanCompleting() {
        let r = GoalsMachine.step(state: probing(),
                                  tick: tick(goals(["fresh goal"]),
                                             tripwire: .fulfilled(completions: ["g9": true])))
        XCTAssertEqual(r.state.phase, .watching)
        XCTAssertFalse(r.effects.contains(.notifyAllDone))
    }
}
