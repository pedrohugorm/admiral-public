import Foundation

/// Owns the session-title decision in one place: the three title line types and the
/// `custom > ai > agent` precedence, with last-non-nil-wins coalescing. Both the full
/// parse and the cheap title-only scan feed lines in and read `resolved`, so the two
/// can't drift.
struct TitleAccumulator {
    private var custom: String?
    private var ai: String?
    private var agent: String?

    mutating func ingest(_ raw: RawLine) {
        switch raw.type {
        case "custom-title": custom = raw.customTitle ?? custom
        case "ai-title": ai = raw.aiTitle ?? ai
        case "agent-name": agent = raw.agentName ?? agent
        default: break
        }
    }

    var resolved: String? { custom ?? ai ?? agent }
}
