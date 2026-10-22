import Foundation

/// Drives the goals nudge from the app tick: reads each managed session's goals, applies
/// `GoalsMachine` effects through the `SessionManager` (PTY injection + the `goals`
/// structured-output slot), and merges each probe answer back into the store.
///
/// It shares an `IdleClock` with the watchdog, which is also what arbitrates between them:
/// whoever injects first restarts the clock, so a session never gets two nudges in one tick.
@MainActor
public final class GoalsService: ObservableObject {
    /// Live nudge phase by `claudeSessionID` — in-memory, rebuilt from the goals themselves.
    @Published public private(set) var states: [String: GoalsWatchState] = [:]

    private let manager: SessionManager
    private let goalsStore: GoalsStore
    private let configProvider: () -> GoalsNudgeConfig
    private let idle: IdleClock
    /// (tabID, title, body) — the app wires this to Notification Center.
    private let notify: (UUID, String, String) -> Void

    public init(manager: SessionManager, goalsStore: GoalsStore,
                configProvider: @escaping () -> GoalsNudgeConfig,
                idle: IdleClock,
                notify: @escaping (UUID, String, String) -> Void) {
        self.manager = manager
        self.goalsStore = goalsStore
        self.configProvider = configProvider
        self.idle = idle
        self.notify = notify
    }

    public func phase(forSession sid: String) -> GoalsPhase {
        states[sid]?.phase ?? .idle
    }

    public func tick(now: Date = Date()) {
        let config = configProvider()
        var liveSIDs = Set<String>()

        for session in manager.sessions {
            guard let sid = session.claudeSessionID, session.status != .shell else { continue }
            liveSIDs.insert(sid)

            let tick = GoalsMachine.Tick(
                config: config,
                goals: goalsStore.goals(forSession: sid),
                // Read, don't re-observe: the watchdog's pass already advanced the clock this
                // tick, and its injection may have just reset it — which is what makes it win.
                idleSeconds: idle.idleSeconds(sid, now: now),
                tripwire: tripwireView(for: session.id),
                now: now)
            let result = GoalsMachine.step(state: states[sid] ?? GoalsWatchState(), tick: tick)
            apply(result.effects, to: session, sid: sid)

            if result.state != states[sid] { states[sid] = result.state }
        }

        states = states.filter { liveSIDs.contains($0.key) }
    }

    /// Map this session's `goals` slot to the machine's view. A fulfilled slot's result is
    /// parsed here — the machine sees completions, not JSON.
    private func tripwireView(for tabID: UUID) -> GoalsMachine.TripwireView {
        guard let stored = manager.structuredOutputState(tabID: tabID, type: .goals) else {
            return .none
        }
        switch stored.status {
        case .armed: return .armedOurs
        case .failed: return .failed
        case .fulfilled:
            guard let entries = stored.result?["goals"]?.arrayValue else { return .failed }
            var completions: [String: Bool] = [:]
            for entry in entries {
                guard let id = entry["id"]?.stringValue,
                      let done = entry["done"]?.boolValue else { continue }
                completions[id] = done
            }
            return .fulfilled(completions: completions)
        }
    }

    private func apply(_ effects: [GoalsMachine.Effect], to session: AgentSession, sid: String) {
        for effect in effects {
            switch effect {
            case let .armProbe(schemaJSON, probeText):
                guard let schema = try? JSONDecoder().decode(
                    JSONValue.self, from: Data(schemaJSON.utf8)) else { continue }  // fail open
                manager.armStructuredOutput(
                    tabID: session.id,
                    spec: StructuredOutputSpec(schema: schema, delivery: .toolUse,
                                               toolName: "set_structured_output", type: .goals))
                manager.inject(session.id, text: probeText)
                idle.wake(sid)
            case let .injectNag(text):
                manager.inject(session.id, text: text)
                idle.wake(sid)
            case .clearTripwire:
                manager.clearStructuredOutput(tabID: session.id, type: .goals)
            case let .applyCompletions(completions):
                goalsStore.update(forSession: sid) { $0.apply(statuses: GoalStatus.statuses(fromDone: completions)) }
            case .notifyAllDone:
                notify(session.id, "Goals met — \(session.displayTitle)",
                       "Every goal on this session is done.")
            }
        }
    }
}
