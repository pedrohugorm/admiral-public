import XCTest
@testable import AdmiralCore

final class WatchdogMachineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private var config: WatchdogConfig!

    override func setUp() {
        super.setUp()
        config = WatchdogConfig(enabled: true)   // rules = [.seeded]
    }

    private func tick(prompts: [String] = [], idle: TimeInterval = 0,
                      tripwire: WatchdogMachine.TripwireView = .none,
                      at date: Date? = nil) -> WatchdogMachine.Tick {
        WatchdogMachine.Tick(config: config, newPrompts: prompts, idleSeconds: idle,
                             tripwire: tripwire, now: date ?? now)
    }

    private func armed() -> WatchdogState {
        WatchdogState(phase: .armed, ruleID: WatchRule.seeded.id,
                      trigger: WatchRule.seeded.trigger,
                      prompt: "go \(WatchRule.seeded.trigger)", armedAt: now)
    }

    private func probing() -> WatchdogState {
        var s = armed()
        s.phase = .probing
        s.lastProbeAt = now
        return s
    }

    // 1
    func testDisabledForcesDisarmAndClearsOurTripwire() {
        config.enabled = false
        let r = WatchdogMachine.step(state: probing(), tick: tick(tripwire: .armedOurs))
        XCTAssertEqual(r.state.phase, .disarmed)
        XCTAssertEqual(r.effects, [.clearTripwire])

        config.enabled = true
        var optedOut = probing()
        optedOut.sessionEnabled = false
        let r2 = WatchdogMachine.step(state: optedOut, tick: tick(tripwire: .armedOurs))
        XCTAssertEqual(r2.state.phase, .disarmed)
        XCTAssertEqual(r2.effects, [.clearTripwire])

        // Disabled ignores prompts entirely.
        config.enabled = false
        let r3 = WatchdogMachine.step(
            state: WatchdogState(), tick: tick(prompts: ["go /drive-ticket to PROD"]))
        XCTAssertEqual(r3.state.phase, .disarmed)
        XCTAssertTrue(r3.effects.isEmpty)
    }

    // 2
    func testTriggerArmsAndRefreshes() {
        let r = WatchdogMachine.step(
            state: WatchdogState(),
            tick: tick(prompts: ["please execute and /DRIVE-ticket to prod now"]))
        XCTAssertEqual(r.state.phase, .armed)
        XCTAssertEqual(r.state.ruleID, WatchRule.seeded.id)
        XCTAssertEqual(r.state.trigger, WatchRule.seeded.trigger)
        XCTAssertEqual(r.state.prompt, "please execute and /DRIVE-ticket to prod now")
        XCTAssertEqual(r.state.armedAt, now)
        XCTAssertTrue(r.effects.isEmpty)

        // Refresh while armed: latest matching prompt wins.
        let r2 = WatchdogMachine.step(
            state: r.state,
            tick: tick(prompts: ["nothing relevant", "again: /drive-ticket to PROD please"],
                       at: now.addingTimeInterval(60)))
        XCTAssertEqual(r2.state.prompt, "again: /drive-ticket to PROD please")
        XCTAssertEqual(r2.state.armedAt, now.addingTimeInterval(60))

        // During probing: directive refreshes, phase stays probing.
        let r3 = WatchdogMachine.step(
            state: probing(),
            tick: tick(prompts: ["hurry /drive-ticket to PROD"], tripwire: .armedOurs))
        XCTAssertEqual(r3.state.phase, .probing)
        XCTAssertEqual(r3.state.prompt, "hurry /drive-ticket to PROD")
        XCTAssertTrue(r3.effects.isEmpty)
    }

    // 3
    func testIdleOverThresholdProbes() {
        let r = WatchdogMachine.step(state: armed(), tick: tick(idle: 5 * 60))
        XCTAssertEqual(r.state.phase, .probing)
        XCTAssertEqual(r.state.lastProbeAt, now)
        guard case let .armProbe(schema, text)? = r.effects.first, r.effects.count == 1 else {
            return XCTFail("expected exactly [armProbe], got \(r.effects)")
        }
        XCTAssertEqual(schema, WatchdogMachine.probeSchemaJSON)
        XCTAssertTrue(text.contains("/drive-ticket to PROD"))
        XCTAssertTrue(text.contains("WATCHDOG CHECK"))
    }

    // 4 — the watchdog owns the `.watchdog` slot outright, so someone else's arm (an API
    // request, a goals nudge) no longer postpones the probe the way a shared slot did.
    func testProbesEvenWhileAnotherFeatureIsArmed() {
        let r = WatchdogMachine.step(state: armed(), tick: tick(idle: 10 * 60, tripwire: .none))
        XCTAssertEqual(r.state.phase, .probing)
        XCTAssertEqual(r.effects.count, 1)
    }

    // 5
    func testIdleBelowThresholdWaits() {
        let r = WatchdogMachine.step(state: armed(), tick: tick(idle: 4 * 60))
        XCTAssertEqual(r.state.phase, .armed)
        XCTAssertTrue(r.effects.isEmpty)
    }

    // 6
    func testDoneDisarmsAndNotifies() {
        let r = WatchdogMachine.step(
            state: probing(),
            tick: tick(tripwire: .fulfilled(status: "done", reason: "prod validated")))
        XCTAssertEqual(r.state.phase, .disarmed)
        XCTAssertNil(r.state.trigger)
        XCTAssertNil(r.state.ruleID)
        XCTAssertNil(r.state.prompt)
        XCTAssertEqual(r.state.lastAnswer, WatchdogAnswer(status: "done", reason: "prod validated"))
        XCTAssertEqual(r.effects, [.clearTripwire, .notifyDone(reason: "prod validated")])
    }

    /// "done" volunteered between checks (the user said to close it) ends the watch then,
    /// not at the next probe.
    func testAVolunteeredDoneBetweenChecksDisarms() {
        let r = WatchdogMachine.step(
            state: armed(), tick: tick(tripwire: .fulfilled(status: "done", reason: "user closed it")))
        XCTAssertEqual(r.state.phase, .disarmed)
        XCTAssertNil(r.state.trigger)
        XCTAssertEqual(r.effects, [.clearTripwire, .notifyDone(reason: "user closed it")])
    }

    /// Anything else volunteered is noted and its slot freed — unasked, so no nag.
    func testAVolunteeredProgressReportIsNotedWithoutANag() {
        let r = WatchdogMachine.step(
            state: armed(), tick: tick(tripwire: .fulfilled(status: "in_progress", reason: "CI")))
        XCTAssertEqual(r.state.phase, .armed)
        XCTAssertEqual(r.state.lastAnswer, WatchdogAnswer(status: "in_progress", reason: "CI"))
        XCTAssertEqual(r.effects, [.clearTripwire])
    }

    // 7
    func testNotDoneNagsWithAnswerContext() {
        let r = WatchdogMachine.step(
            state: probing(),
            tick: tick(tripwire: .fulfilled(status: "blocked", reason: "CI outage")))
        XCTAssertEqual(r.state.phase, .armed)
        XCTAssertEqual(r.state.cycles, 1)
        XCTAssertEqual(r.state.lastAnswer, WatchdogAnswer(status: "blocked", reason: "CI outage"))
        XCTAssertEqual(r.effects.first, .clearTripwire)
        guard case let .injectNag(text)? = r.effects.last, r.effects.count == 2 else {
            return XCTFail("expected [clearTripwire, injectNag], got \(r.effects)")
        }
        XCTAssertTrue(text.contains("/drive-ticket to PROD"))
    }

    // 8
    func testFailedTripwireNags() {
        let r = WatchdogMachine.step(state: probing(), tick: tick(tripwire: .failed))
        XCTAssertEqual(r.state.phase, .armed)
        XCTAssertEqual(r.state.cycles, 1)
        XCTAssertEqual(r.effects.first, .clearTripwire)
        guard case .injectNag? = r.effects.last else {
            return XCTFail("expected injectNag, got \(r.effects)")
        }
    }

    // 9
    func testProbeTimeoutNags() {
        let r = WatchdogMachine.step(
            state: probing(),
            tick: tick(tripwire: .armedOurs, at: now.addingTimeInterval(3 * 60)))
        XCTAssertEqual(r.state.phase, .armed)
        XCTAssertEqual(r.state.cycles, 1)
        XCTAssertEqual(r.effects.first, .clearTripwire)
        guard case .injectNag? = r.effects.last else {
            return XCTFail("expected injectNag, got \(r.effects)")
        }
    }

    // 10
    func testProbeWithinTimeoutWaits() {
        let r = WatchdogMachine.step(
            state: probing(),
            tick: tick(tripwire: .armedOurs, at: now.addingTimeInterval(60)))
        XCTAssertEqual(r.state.phase, .probing)
        XCTAssertTrue(r.effects.isEmpty)
    }

    // 11
    func testVanishedTripwireNagsDirectly() {
        let r = WatchdogMachine.step(state: probing(), tick: tick(tripwire: .none))
        XCTAssertEqual(r.state.phase, .armed)
        XCTAssertEqual(r.state.cycles, 1)
        guard case .injectNag? = r.effects.first, r.effects.count == 1 else {
            return XCTFail("expected exactly [injectNag], got \(r.effects)")
        }
    }

    // 12
    func testDeletedRuleDisarms() {
        config.rules = []
        let r = WatchdogMachine.step(state: probing(), tick: tick(tripwire: .armedOurs))
        XCTAssertEqual(r.state.phase, .disarmed)
        XCTAssertEqual(r.effects, [.clearTripwire])

        let r2 = WatchdogMachine.step(state: armed(), tick: tick(idle: 10 * 60))
        XCTAssertEqual(r2.state.phase, .disarmed)
        XCTAssertTrue(r2.effects.isEmpty)
    }

    func testMatchRuleSemantics() {
        let empty = WatchRule(trigger: "", probeTemplate: "p", nagTemplate: "n")
        let exam = WatchRule(trigger: "/exam-loop", probeTemplate: "p", nagTemplate: "n")
        XCTAssertNil(WatchdogMachine.matchRule(prompt: "anything", rules: [empty]))
        XCTAssertEqual(
            WatchdogMachine.matchRule(prompt: "run /EXAM-loop now", rules: [empty, .seeded, exam])?.id,
            exam.id)
        XCTAssertNil(WatchdogMachine.matchRule(prompt: "no triggers here", rules: [.seeded, exam]))
    }
}
