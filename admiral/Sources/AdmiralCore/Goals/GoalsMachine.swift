import Foundation

/// App-level goals-nudge configuration (Settings → Watchdog, Goals card). Independent of the watchdog's
/// master toggle: goals are useful without arming the drive-to-PROD babysitter, and turning
/// that off should not silently stop goals being chased.
public struct GoalsNudgeConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var idleThresholdMinutes: Int
    public var probeTimeoutMinutes: Int

    public init(enabled: Bool = true, idleThresholdMinutes: Int = 5, probeTimeoutMinutes: Int = 3) {
        self.enabled = enabled
        self.idleThresholdMinutes = idleThresholdMinutes
        self.probeTimeoutMinutes = probeTimeoutMinutes
    }

    public static let `default` = GoalsNudgeConfig()
}

public enum GoalsPhase: String, Codable, Sendable {
    case idle, watching, probing
}

/// Per-session nudge state. Deliberately in-memory only: the durable half (the goals) lives
/// in `GoalsStore`, and everything here is rebuildable from "are there outstanding goals?"
/// on the next tick, so a relaunch costs at most one idle threshold.
public struct GoalsWatchState: Equatable, Sendable {
    public var phase: GoalsPhase
    public var lastProbeAt: Date?
    public var cycles: Int

    public init(phase: GoalsPhase = .idle, lastProbeAt: Date? = nil, cycles: Int = 0) {
        self.phase = phase
        self.lastProbeAt = lastProbeAt
        self.cycles = cycles
    }
}

/// The goals nudge's pure state machine: one `step` per app tick, per session — the same
/// shape as `WatchdogMachine`, for the same reason (every transition is a fast unit test).
///
/// Where the watchdog chases one directive it spotted in a prompt, this chases the goals a
/// peer set over the bridge, and the probe's structured answer is what marks them done.
public enum GoalsMachine {
    /// The answer contract for the `goals` slot — a different schema from the watchdog's,
    /// which is the whole point of typing the slots.
    public static let probeSchemaJSON = #"{"type":"object","properties":{"goals":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"done":{"type":"boolean"},"note":{"type":"string"}},"required":["id","done"]}}},"required":["goals"]}"#

    /// This session's `goals` slot.
    public enum TripwireView: Equatable, Sendable {
        case none
        case armedOurs
        case fulfilled(completions: [String: Bool])
        case failed
    }

    public struct Tick {
        public var config: GoalsNudgeConfig
        public var goals: SessionGoals?
        public var idleSeconds: TimeInterval
        public var tripwire: TripwireView
        public var now: Date

        public init(config: GoalsNudgeConfig, goals: SessionGoals?,
                    idleSeconds: TimeInterval = 0, tripwire: TripwireView = .none, now: Date) {
            self.config = config
            self.goals = goals
            self.idleSeconds = idleSeconds
            self.tripwire = tripwire
            self.now = now
        }
    }

    public enum Effect: Equatable, Sendable {
        case armProbe(schemaJSON: String, probeText: String)
        case injectNag(String)
        case clearTripwire
        /// Merge the probe's answer into the store (the machine stays pure).
        case applyCompletions([String: Bool])
        case notifyAllDone
    }

    public static func step(state: GoalsWatchState,
                            tick: Tick) -> (state: GoalsWatchState, effects: [Effect]) {
        var state = state

        // Nothing to chase: disabled, no goals, or every goal already met. Release our slot
        // so the session isn't left owing an answer nobody will read.
        let outstanding = tick.config.enabled ? (tick.goals?.outstanding ?? []) : []
        guard !outstanding.isEmpty else {
            let owed = state.phase == .probing && tick.tripwire == .armedOurs
            state = GoalsWatchState()
            return (state, owed ? [.clearTripwire] : [])
        }

        switch state.phase {
        case .idle:
            state.phase = .watching
            return (state, [])

        case .watching:
            let threshold = TimeInterval(tick.config.idleThresholdMinutes * 60)
            guard tick.idleSeconds >= threshold else { return (state, []) }
            state.phase = .probing
            state.lastProbeAt = tick.now
            return (state, [.armProbe(schemaJSON: probeSchemaJSON,
                                      probeText: GoalsTemplate.probe(outstanding))])

        case .probing:
            func nag() -> (GoalsWatchState, [Effect]) {
                state.phase = .watching
                state.cycles += 1
                return (state, [.clearTripwire, .injectNag(GoalsTemplate.nag(outstanding))])
            }
            switch tick.tripwire {
            case let .fulfilled(completions):
                // Decide against the MERGED list, not the stale one: whether this answer
                // finishes the goals is exactly the question the merge answers.
                var merged = tick.goals ?? SessionGoals(goals: [], setAt: tick.now)
                merged.apply(statuses: GoalStatus.statuses(fromDone: completions), now: tick.now)
                guard merged.isComplete else {
                    state.phase = .watching
                    state.cycles += 1
                    return (state, [.applyCompletions(completions), .clearTripwire,
                                    .injectNag(GoalsTemplate.nag(merged.outstanding))])
                }
                state = GoalsWatchState()
                return (state, [.applyCompletions(completions), .clearTripwire, .notifyAllDone])

            case .failed:
                // 3 invalid attempts or 3 ignored Stop blocks — stonewalling is not escape.
                return nag()

            case .armedOurs:
                let timeout = TimeInterval(tick.config.probeTimeoutMinutes * 60)
                guard let probed = state.lastProbeAt,
                      tick.now.timeIntervalSince(probed) >= timeout else { return (state, []) }
                return nag()

            case .none:
                // Our slot vanished (cleared externally / app relaunch). The probe is
                // unanswerable — reclaim by nagging directly.
                state.phase = .watching
                state.cycles += 1
                return (state, [.injectNag(GoalsTemplate.nag(outstanding))])
            }
        }
    }
}

/// The nudge's wording. Not user-templated like the watchdog's: these messages are derived
/// from the goals themselves, so there is nothing for a template to say that the goal text
/// doesn't already.
public enum GoalsTemplate {
    public static func probe(_ outstanding: [SessionGoal]) -> String {
        "GOALS CHECK — these goals are still open: \(numbered(outstanding)). Report which are "
            + "now met via set_structured_output with `type` set to \"goals\" (one entry per "
            + "goal id, with `done` true or false)."
    }

    public static func nag(_ outstanding: [SessionGoal]) -> String {
        "Still open: \(numbered(outstanding)). Why are you waiting? Keep going until these "
            + "are met."
    }

    /// `g1) ship it g2) verify in rnd` — ids included so the probe's answer can name them.
    static func numbered(_ goals: [SessionGoal]) -> String {
        goals.map { "\($0.id)) \($0.text)" }.joined(separator: " ")
    }
}
