import Foundation

/// Drives the watchdog from the app tick: reads each managed session's new prompts,
/// tracks continuous idle, and applies `WatchdogMachine` effects through the
/// `SessionManager` (PTY injection + structured-output tripwire). `@MainActor` because
/// it mutates published state and calls into the `@MainActor` SessionManager.
@MainActor
public final class WatchdogService: ObservableObject {
    /// Live watchdog state by `claudeSessionID` — the sidebar badge and context menu read this.
    @Published public private(set) var states: [String: WatchdogState] = [:]

    private let manager: SessionManager
    private let stateStore: WatchdogStateStore
    private let configProvider: () -> WatchdogConfig
    /// (tabID, title, body) — the app wires this to Notification Center.
    private let notify: (UUID, String, String) -> Void
    /// Shared with every other idle-driven nudge, so one injection silences them all.
    private let idle: IdleClock
    private var promptOffsets: [String: UInt64] = [:]

    public init(manager: SessionManager, stateStore: WatchdogStateStore,
                configProvider: @escaping () -> WatchdogConfig,
                idle: IdleClock,
                notify: @escaping (UUID, String, String) -> Void) {
        self.manager = manager
        self.stateStore = stateStore
        self.configProvider = configProvider
        self.idle = idle
        self.notify = notify
    }

    public func phase(forSession sid: String) -> WatchdogPhase {
        states[sid]?.phase ?? stateStore.state(forSession: sid)?.phase ?? .disarmed
    }

    public func sessionEnabled(_ sid: String) -> Bool {
        (states[sid] ?? stateStore.state(forSession: sid))?.sessionEnabled ?? true
    }

    /// The right-click toggle. Disabling mid-probe releases the tripwire on the next tick.
    public func setSessionEnabled(_ sid: String, _ enabled: Bool) {
        var state = states[sid] ?? stateStore.state(forSession: sid) ?? WatchdogState()
        state.sessionEnabled = enabled
        states[sid] = state
        stateStore.set(state, forSession: sid)
    }

    public func tick(now: Date = Date()) {
        let config = configProvider()
        var liveSIDs = Set<String>()

        for session in manager.sessions {
            guard let sid = session.claudeSessionID, session.status != .shell else { continue }
            liveSIDs.insert(sid)
            let state = states[sid] ?? stateStore.state(forSession: sid) ?? WatchdogState()

            let idleSeconds = idle.observe(sid, status: session.status, now: now)

            let log = AdmiralPaths.promptsLog(base: manager.supportDir, token: session.token)
            let read = PromptLogReader.read(url: log, offset: promptOffsets[session.token] ?? 0)
            promptOffsets[session.token] = read.offset

            let tick = WatchdogMachine.Tick(
                config: config,
                newPrompts: read.events.map(\.prompt),
                idleSeconds: idleSeconds,
                tripwire: tripwireView(for: session.id),
                now: now)
            let result = WatchdogMachine.step(state: state, tick: tick)
            apply(result.effects, to: session)

            if result.state != states[sid] {
                states[sid] = result.state
                stateStore.set(result.state, forSession: sid)
            }
            syncReminderMarker(result.state, token: session.token)
        }

        // Sessions that closed take their in-memory bookkeeping with them; the persistent
        // store keeps its entry so a resumed session picks its watchdog back up.
        states = states.filter { liveSIDs.contains($0.key) }
        idle.keepOnly(liveSIDs)
    }

    /// What each session's reminder marker says, so the file is touched only on a change.
    /// `.some(nil)` = known absent; a missing key = not yet synced this launch.
    private var markers: [String: String?] = [:]

    /// Mirror "armed, and for what" to the file the Stop hook reads (`WatchdogReminder`).
    private func syncReminderMarker(_ state: WatchdogState, token: String) {
        let want = state.phase == .disarmed ? nil : state.trigger
        if let known = markers[token], known == want { return }
        if let want {
            WatchdogReminder.mark(trigger: want, base: manager.supportDir, token: token)
        } else {
            WatchdogReminder.unmark(base: manager.supportDir, token: token)
        }
        markers[token] = .some(want)
    }

    /// Map the watchdog's own slot to the machine's view. The slot is keyed by `.watchdog`,
    /// so nothing else can be in it — there is no "is this mine?" question left to ask.
    private func tripwireView(for tabID: UUID) -> WatchdogMachine.TripwireView {
        guard let stored = manager.structuredOutputState(tabID: tabID, type: .watchdog) else {
            return .none
        }
        switch stored.status {
        case .armed: return .armedOurs
        case .failed: return .failed
        case .fulfilled:
            guard let status = stored.result?["status"]?.stringValue else { return .failed }
            let reason = stored.result?["reason"]?.stringValue ?? ""
            return .fulfilled(status: status, reason: reason)
        }
    }

    private func apply(_ effects: [WatchdogMachine.Effect], to session: AgentSession) {
        guard let sid = session.claudeSessionID else { return }
        for effect in effects {
            switch effect {
            case let .armProbe(_, probeText):
                guard let spec = WatchdogMachine.probeSpec else { continue }  // fail open
                manager.armStructuredOutput(tabID: session.id, spec: spec)
                manager.deliver(session.id, text: probeText)
                idle.wake(sid)   // injection wakes the session; restart the idle clock
            case let .injectNag(text):
                manager.deliver(session.id, text: text)
                idle.wake(sid)
            case .clearTripwire:
                manager.clearStructuredOutput(tabID: session.id, type: .watchdog)
            case let .notifyDone(reason):
                notify(session.id, "Watchdog — \(session.displayTitle)", "Claims done: \(reason)")
            }
        }
    }
}
