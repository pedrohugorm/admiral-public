import Foundation

/// Where a PR stands on being merged — one value in place of `PRStatus`'s `isMerged` +
/// `canMerge` pair, so "did anything change" is a single comparison rather than a truth table.
public enum PRState: String, Codable, Sendable {
    case blocked, mergeable, merged

    public init(_ pr: PRStatus) {
        if pr.isMerged { self = .merged } else { self = pr.canMerge ? .mergeable : .blocked }
    }
}

/// The CI verdict, coarse on purpose. A running suite counts down (5 running → 4 → 3 …) and
/// diffing those numbers would announce a dozen times per run; the session only ever needs to
/// know which of four situations it is in. Failure beats running beats passing — the worst
/// news is the news.
public enum ChecksState: String, Codable, Sendable {
    case none, running, passed, failed

    public init(_ pr: PRStatus) {
        if pr.checksFailed > 0 { self = .failed }
        else if pr.checksRunning > 0 { self = .running }
        else { self = pr.checksPassed > 0 ? .passed : .none }
    }

    var phrase: String {
        switch self {
        case .none: return "no checks"
        case .running: return "checks running"
        case .passed: return "checks passed"
        case .failed: return "checks FAILED"
        }
    }
}

/// What Admiral remembers about one PR between polls: enough to tell the session what
/// changed, and nothing that changes on its own.
public struct PRDigest: Codable, Equatable, Sendable {
    public var number: Int
    public var title: String
    public var url: String
    public var state: PRState
    public var checks: ChecksState
    public var approvals: Int

    public init(number: Int, title: String, url: String,
                state: PRState, checks: ChecksState, approvals: Int) {
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.checks = checks
        self.approvals = approvals
    }

    public init(_ pr: PRStatus) {
        self.init(number: pr.number, title: pr.title, url: pr.url,
                  state: PRState(pr), checks: ChecksState(pr), approvals: pr.approvals)
    }

    /// The fields that make a change worth announcing. Title and URL are payload: a PR whose
    /// title was edited is not news, and re-announcing on it would be pure noise.
    public var signature: String { "\(state.rawValue)/\(checks.rawValue)/\(approvals)" }

    /// "mergeable · checks passed · 1 approval" — the whole standing, one line.
    public var summary: String {
        "\(state.rawValue) · \(checks.phrase) · \(approvals) approval\(approvals == 1 ? "" : "s")"
    }

    /// What changed since `before` (nil = never announced), one phrase per field. Empty means
    /// nothing worth saying — the caller checks `signature` first, so this is only reached
    /// when at least one phrase will come out.
    func deltas(since before: PRDigest?) -> [String] {
        guard let before else { return [summary] }
        var out: [String] = []
        if before.state != state { out.append("\(state.rawValue) (was \(before.state.rawValue))") }
        if before.checks != checks { out.append("\(checks.phrase) (was \(before.checks.phrase))") }
        if before.approvals != approvals {
            out.append("\(approvals) approval\(approvals == 1 ? "" : "s") (was \(before.approvals))")
        }
        return out
    }
}
