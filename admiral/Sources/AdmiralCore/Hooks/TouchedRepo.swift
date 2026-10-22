import Foundation

/// One git repository a session has written to, aggregated from its hook append-log. A repo
/// can be worked on across several branches in one session, so it carries the *set* of distinct
/// `branches` it was touched on (first-seen order) and the `prs` found across them — one PR
/// chip per branch, rather than collapsing to a single branch/PR (which made the chip alternate
/// when two branches each had a PR). `prs` is filled in app-side (off the throttled `gh` loop);
/// the reader leaves it empty.
public struct TouchedRepo: Identifiable, Equatable, Hashable, Sendable {
    public var id: String { root }
    public let root: String
    public var branches: [String]
    public var filesWritten: Int
    public let insideSessionRoot: Bool
    public var prs: [PRStatus]

    public init(root: String, branches: [String], filesWritten: Int,
                insideSessionRoot: Bool, prs: [PRStatus] = []) {
        self.root = root
        self.branches = branches
        self.filesWritten = filesWritten
        self.insideSessionRoot = insideSessionRoot
        self.prs = prs
    }
}

/// One line in `touched.jsonl` — a single write event captured by a PostToolUse hook.
/// `repoRoot`/`branch` are nil when the file is not inside a git repo (recorded, not surfaced).
public struct TouchedRepoEvent: Codable, Equatable, Sendable {
    public let ts: String
    public let tool: String
    public let filePath: String
    public let repoRoot: String?
    public let branch: String?
    public let insideSessionRoot: Bool

    public init(ts: String, tool: String, filePath: String,
                repoRoot: String?, branch: String?, insideSessionRoot: Bool) {
        self.ts = ts
        self.tool = tool
        self.filePath = filePath
        self.repoRoot = repoRoot
        self.branch = branch
        self.insideSessionRoot = insideSessionRoot
    }
}
