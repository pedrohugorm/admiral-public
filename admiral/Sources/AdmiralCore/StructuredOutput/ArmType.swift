import Foundation

/// Which feature armed a structured-output slot.
///
/// A session can owe more than one answer at a time — the Anthropic endpoint's request, the
/// watchdog's probe, the goals nudge — so the tripwire is keyed by this value instead of
/// being one slot every feature has to check isn't someone else's.
///
/// **Declaration order IS the Stop-hook priority.** A Stop block carries exactly one reason,
/// so when several slots are armed the first one here wins the turn and the rest keep
/// waiting: an in-flight API request must never starve behind a nag. `output` (a tab's own
/// per-turn schema, `OutputSchemaStore`) comes next: it is owed every turn, by contract.
public enum ArmType: String, Codable, CaseIterable, Sendable {
    case api, output, watchdog, goals

    /// `api, output, watchdog, goals` — for error text that has to name the valid values.
    public static var names: String {
        allCases.map(\.rawValue).joined(separator: ", ")
    }
}
