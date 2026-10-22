import Foundation

/// What a session has been polled for and what it has been *told* — the two are separate on
/// purpose.
///
/// `repos` is the last poll, and is what `pr_status` reports; it is written every cycle so a
/// session asking mid-turn never reads hours-old data. `announced` is the re-trigger guard:
/// only a change the session was actually shown lands here, so a busy session that could not
/// be told yet re-detects the same change next cycle instead of losing it — and a relaunch
/// (or a `--resume`) reloads it, sees no delta, and stays quiet.
public struct PRWatchState: Codable, Equatable, Sendable {
    /// Latest poll, by repo root.
    public var repos: [String: [PRDigest]]
    /// The digest the session was last told about, keyed `<root>#<number>`.
    public var announced: [String: PRDigest]
    public var checkedAt: Date?

    public init(repos: [String: [PRDigest]] = [:],
                announced: [String: PRDigest] = [:],
                checkedAt: Date? = nil) {
        self.repos = repos
        self.announced = announced
        self.checkedAt = checkedAt
    }

    public static func key(root: String, number: Int) -> String { "\(root)#\(number)" }

    /// Every repo whose PRs are all merged — nothing left to learn there, so the service
    /// drops to a cooldown cadence rather than polling it at full rate.
    public func isSettled(root: String) -> Bool {
        guard let digests = repos[root], !digests.isEmpty else { return false }
        return digests.allSatisfy { $0.state == .merged }
    }
}

/// One PR's news, ready to render.
public struct PRChange: Equatable, Sendable {
    public let root: String
    public let digest: PRDigest
    public let deltas: [String]

    public init(root: String, digest: PRDigest, deltas: [String]) {
        self.root = root
        self.digest = digest
        self.deltas = deltas
    }

    /// The repo's own name, not its path — the session knows where it is working.
    var repoName: String { (root as NSString).lastPathComponent }

    var block: String {
        "\(repoName) #\(digest.number) \"\(digest.title)\"\n"
            + "  \(deltas.joined(separator: " · "))\n  \(digest.url)"
    }
}

/// The injected message. One header however many PRs moved, so a session that was busy while
/// three things changed gets one interruption rather than three. Facts only: how to treat it
/// is said once, in `NudgeInstructions`, rather than in every message that stays in context.
public enum PRWatchMessage {
    public static func text(for changes: [PRChange]) -> String {
        "PR WATCH — \(changes.count == 1 ? "a pull request" : "\(changes.count) pull requests") "
            + "you are working on changed:\n"
            + changes.map(\.block).joined(separator: "\n")
    }
}
