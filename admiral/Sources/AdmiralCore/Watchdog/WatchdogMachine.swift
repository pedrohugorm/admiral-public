import Foundation

/// The watchdog's pure state machine: one `step` per app tick, per session. All I/O —
/// prompt reading, idle measurement, tripwire storage, PTY injection, notifications —
/// happens in `WatchdogService`; this type only maps (state, observations) → (state,
/// effects), which is what makes every transition unit-testable.
public enum WatchdogMachine {
    /// The probe answer contract: `set_structured_output` must deliver exactly this shape.
    public static let probeSchemaJSON = #"{"type":"object","properties":{"status":{"type":"string","enum":["done","blocked","in_progress"]},"reason":{"type":"string"}},"required":["status","reason"]}"#

    /// The slot a watchdog answer goes into — armed by a probe, or on demand when the agent
    /// reports before being asked. nil only if the schema literal stops parsing (fail open).
    public static var probeSpec: StructuredOutputSpec? {
        guard let schema = try? JSONDecoder().decode(JSONValue.self, from: Data(probeSchemaJSON.utf8))
        else { return nil }
        return StructuredOutputSpec(schema: schema, delivery: .toolUse,
                                    toolName: "set_structured_output", type: .watchdog)
    }

    /// The watchdog's own structured-output slot (`ArmType.watchdog`). Nothing else can
    /// occupy it, so there is no foreign-arm case to defend against.
    public enum TripwireView: Equatable, Sendable {
        case none
        case armedOurs
        case fulfilled(status: String, reason: String)
        case failed
    }

    /// One tick's observations for one session.
    public struct Tick {
        public var config: WatchdogConfig
        public var newPrompts: [String]
        public var idleSeconds: TimeInterval
        public var tripwire: TripwireView
        public var now: Date
        public init(config: WatchdogConfig, newPrompts: [String] = [],
                    idleSeconds: TimeInterval = 0, tripwire: TripwireView = .none, now: Date) {
            self.config = config
            self.newPrompts = newPrompts
            self.idleSeconds = idleSeconds
            self.tripwire = tripwire
            self.now = now
        }
    }

    public enum Effect: Equatable, Sendable {
        case armProbe(schemaJSON: String, probeText: String)
        case injectNag(String)
        case clearTripwire
        case notifyDone(reason: String)
    }

    /// First rule whose trigger appears in `prompt` (case-insensitive substring).
    /// Empty triggers never match — they'd match everything.
    public static func matchRule(prompt: String, rules: [WatchRule]) -> WatchRule? {
        rules.first { rule in
            !rule.trigger.isEmpty
                && prompt.range(of: rule.trigger, options: .caseInsensitive) != nil
        }
    }

    public static func step(state: WatchdogState, tick: Tick) -> (state: WatchdogState, effects: [Effect]) {
        var state = state

        // Disabled (master or per-tab) forces disarm; release our tripwire so the
        // session isn't left owing an answer nobody will read.
        guard tick.config.enabled, state.sessionEnabled else {
            let ours = state.phase == .probing && tick.tripwire == .armedOurs
            state.phase = .disarmed
            return (state, ours ? [.clearTripwire] : [])
        }

        // Trigger detection — the LAST matching prompt wins (it's the freshest directive).
        for prompt in tick.newPrompts {
            guard let rule = matchRule(prompt: prompt, rules: tick.config.rules) else { continue }
            state.ruleID = rule.id
            state.trigger = rule.trigger
            state.prompt = prompt
            if state.phase != .probing {
                state.phase = .armed
                state.armedAt = tick.now
            }
        }

        guard state.phase != .disarmed else { return (state, []) }

        // The armed rule's templates. A rule deleted from config mid-flight disarms —
        // there is nothing left to render, and silently switching templates would nag
        // with someone else's words.
        guard let rule = tick.config.rules.first(where: { $0.id == state.ruleID }) else {
            let ours = state.phase == .probing && tick.tripwire == .armedOurs
            state.phase = .disarmed
            return (state, ours ? [.clearTripwire] : [])
        }

        let idleMinutes = Int(tick.idleSeconds / 60)
        func render(_ template: String) -> String {
            WatchdogTemplate.render(template,
                                    trigger: state.trigger, prompt: state.prompt,
                                    status: state.lastAnswer?.status,
                                    reason: state.lastAnswer?.reason,
                                    idleMinutes: idleMinutes)
        }

        /// "done" ends the watch however it arrived — probed or volunteered.
        func finish(_ reason: String) -> (WatchdogState, [Effect]) {
            state.phase = .disarmed
            state.ruleID = nil
            state.trigger = nil
            state.prompt = nil
            state.armedAt = nil
            state.lastProbeAt = nil
            return (state, [.clearTripwire, .notifyDone(reason: reason)])
        }

        switch state.phase {
        case .disarmed:
            return (state, [])

        case .armed:
            // A report the agent volunteered between checks (the user said "it's done").
            // "done" disarms; anything else is noted and the slot freed — it was not asked
            // for, so there is nothing to nag about.
            switch tick.tripwire {
            case let .fulfilled(status, reason):
                state.lastAnswer = WatchdogAnswer(status: status, reason: reason)
                return status == "done" ? finish(reason) : (state, [.clearTripwire])
            case .failed:
                return (state, [.clearTripwire])
            case .none, .armedOurs:
                break
            }
            let threshold = TimeInterval(tick.config.idleThresholdMinutes * 60)
            guard tick.idleSeconds >= threshold else { return (state, []) }
            state.phase = .probing
            state.lastProbeAt = tick.now
            return (state, [.armProbe(schemaJSON: probeSchemaJSON,
                                      probeText: render(rule.probeTemplate))])

        case .probing:
            func nag() -> (WatchdogState, [Effect]) {
                state.phase = .armed
                state.cycles += 1
                return (state, [.clearTripwire, .injectNag(render(rule.nagTemplate))])
            }
            switch tick.tripwire {
            case let .fulfilled(status, reason):
                state.lastAnswer = WatchdogAnswer(status: status, reason: reason)
                if status == "done" { return finish(reason) }
                return nag()
            case .failed:
                // 3 invalid attempts or 3 ignored Stop blocks — stonewalling is not escape.
                return nag()
            case .armedOurs:
                let timeout = TimeInterval(tick.config.probeTimeoutMinutes * 60)
                guard let probed = state.lastProbeAt,
                      tick.now.timeIntervalSince(probed) >= timeout else { return (state, []) }
                return nag()
            case .none:
                // Our tripwire vanished (cleared externally / app relaunch under a new
                // token). The probe is unanswerable — reclaim by nagging directly.
                state.phase = .armed
                state.cycles += 1
                return (state, [.injectNag(render(rule.nagTemplate))])
            }
        }
    }
}
