import Foundation

/// One watchdog rule: a trigger phrase to spot in a session's prompts, and the probe/nag
/// message templates injected while that directive is unmet. Template variables:
/// `{trigger}` (matched phrase), `{prompt}` (full prompt that armed it), `{status}` /
/// `{reason}` (last probe answer), `{idle_minutes}` (continuous idle when the cycle fired).
public struct WatchRule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var trigger: String
    public var probeTemplate: String
    public var nagTemplate: String

    public init(id: UUID = UUID(), trigger: String, probeTemplate: String, nagTemplate: String) {
        self.id = id
        self.trigger = trigger
        self.probeTemplate = probeTemplate
        self.nagTemplate = nagTemplate
    }

    /// The flagship rule the feature ships with — the drive-to-PROD babysitter. "Continue after
    /// reporting" is said once, in `NudgeInstructions`, not in every probe.
    public static let seeded = WatchRule(
        trigger: "/drive-ticket to PROD",
        probeTemplate: "WATCHDOG CHECK — you were told: \"{trigger}\". Is that fully done "
            + "(deployed AND validated in PROD)? Report via set_structured_output.",
        nagTemplate: "Did you drive to prod? Why are you waiting? {trigger}"
    )
}

/// App-level watchdog configuration (Settings → Watchdog). Master toggle default OFF.
public struct WatchdogConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var idleThresholdMinutes: Int
    public var probeTimeoutMinutes: Int
    public var rules: [WatchRule]

    public init(enabled: Bool = false, idleThresholdMinutes: Int = 5,
                probeTimeoutMinutes: Int = 3, rules: [WatchRule] = [.seeded]) {
        self.enabled = enabled
        self.idleThresholdMinutes = idleThresholdMinutes
        self.probeTimeoutMinutes = probeTimeoutMinutes
        self.rules = rules
    }

    public static let `default` = WatchdogConfig()
}

public enum WatchdogPhase: String, Codable, Sendable {
    case disarmed, armed, probing
}

/// The parsed probe answer the tripwire forced out of the session.
public struct WatchdogAnswer: Codable, Equatable, Sendable {
    public var status: String
    public var reason: String
    public init(status: String, reason: String) {
        self.status = status
        self.reason = reason
    }
}

/// Per-session watchdog state, persisted keyed by `claudeSessionID` so an armed watchdog
/// survives app relaunch and `--resume`. `sessionEnabled` persists across phases so a tab
/// opted out via right-click stays out even while disarmed.
public struct WatchdogState: Codable, Equatable, Sendable {
    public var phase: WatchdogPhase
    public var ruleID: UUID?
    public var trigger: String?
    public var prompt: String?
    public var armedAt: Date?
    public var lastProbeAt: Date?
    public var cycles: Int
    public var lastAnswer: WatchdogAnswer?
    public var sessionEnabled: Bool

    public init(phase: WatchdogPhase = .disarmed, ruleID: UUID? = nil, trigger: String? = nil,
                prompt: String? = nil, armedAt: Date? = nil, lastProbeAt: Date? = nil,
                cycles: Int = 0, lastAnswer: WatchdogAnswer? = nil, sessionEnabled: Bool = true) {
        self.phase = phase
        self.ruleID = ruleID
        self.trigger = trigger
        self.prompt = prompt
        self.armedAt = armedAt
        self.lastProbeAt = lastProbeAt
        self.cycles = cycles
        self.lastAnswer = lastAnswer
        self.sessionEnabled = sessionEnabled
    }
}

/// One captured UserPromptSubmit, appended by the hook helper to `prompts.jsonl`.
public struct PromptEvent: Codable, Equatable, Sendable {
    public var ts: String
    public var prompt: String
    public init(ts: String, prompt: String) {
        self.ts = ts
        self.prompt = prompt
    }
}
