import Foundation

/// The merge-readiness of a branch's pull request, distilled from `gh pr list --json …`.
/// Pure data + parsing so it's unit-testable without touching the network.
public struct PRStatus: Equatable, Hashable, Sendable {
    public let number: Int
    public let title: String
    public let url: String
    public let isMerged: Bool
    /// The merge button is actually pressable — GitHub `mergeStateStatus` is CLEAN (or
    /// UNSTABLE: only non-required checks pending/failing). NOT just conflict-free:
    /// BLOCKED (missing required approvals/checks) and DIRTY (conflicts) are `false`.
    public let canMerge: Bool
    public let approvals: Int
    public let checksPassed: Int
    public let checksRunning: Int
    public let checksFailed: Int

    public init(number: Int, title: String, url: String, isMerged: Bool, canMerge: Bool,
                approvals: Int, checksPassed: Int, checksRunning: Int, checksFailed: Int) {
        self.number = number; self.title = title; self.url = url
        self.isMerged = isMerged; self.canMerge = canMerge; self.approvals = approvals
        self.checksPassed = checksPassed; self.checksRunning = checksRunning; self.checksFailed = checksFailed
    }

    /// Parse `gh pr list … --json number,state,mergeStateStatus,latestReviews,
    /// statusCheckRollup,url,title` output. Picks the PR to show: a non-merged (OPEN) one
    /// if any (most recent number), else the most-recent of the rest (shown as MERGED).
    public static func from(ghJSON data: Data) -> PRStatus? {
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              !arr.isEmpty else { return nil }
        let byNumber: ([String: Any], [String: Any]) -> Bool = {
            ($0["number"] as? Int ?? 0) < ($1["number"] as? Int ?? 0)
        }
        let state: ([String: Any]) -> String = { ($0["state"] as? String)?.uppercased() ?? "" }
        // Prefer an OPEN PR; else the most-recent MERGED. CLOSED-unmerged PRs aren't
        // actionable (e.g. old main→dev merge PRs on a `main` worktree) — ignore them.
        let open = arr.filter { state($0) == "OPEN" }
        let merged = arr.filter { state($0) == "MERGED" }
        guard let pr = open.max(by: byNumber) ?? merged.max(by: byNumber) else { return nil }
        return parse(pr)
    }

    static func parse(_ pr: [String: Any]) -> PRStatus {
        let mergeState = (pr["mergeStateStatus"] as? String)?.uppercased() ?? ""
        let approvals = ((pr["latestReviews"] as? [[String: Any]]) ?? [])
            .filter { ($0["state"] as? String)?.uppercased() == "APPROVED" }.count
        var passed = 0, running = 0, failed = 0
        for check in (pr["statusCheckRollup"] as? [[String: Any]]) ?? [] {
            switch outcome(of: check) {
            case .passed: passed += 1
            case .running: running += 1
            case .failed: failed += 1
            }
        }
        return PRStatus(
            number: pr["number"] as? Int ?? 0,
            title: pr["title"] as? String ?? "",
            url: pr["url"] as? String ?? "",
            isMerged: (pr["state"] as? String)?.uppercased() == "MERGED",
            canMerge: mergeState == "CLEAN" || mergeState == "UNSTABLE",
            approvals: approvals,
            checksPassed: passed, checksRunning: running, checksFailed: failed
        )
    }

    private enum Outcome { case passed, running, failed }

    /// A statusCheckRollup entry is a CheckRun (`status` + `conclusion`) or a StatusContext
    /// (`state`). Classify into passed / running / failed.
    private static func outcome(of check: [String: Any]) -> Outcome {
        let conclusion = (check["conclusion"] as? String)?.uppercased() ?? ""
        let status = (check["status"] as? String)?.uppercased() ?? ""
        let state = (check["state"] as? String)?.uppercased() ?? ""
        let failing: Set<String> = ["FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE"]
        let inFlight: Set<String> = ["QUEUED", "IN_PROGRESS", "PENDING", "WAITING", "REQUESTED"]
        if failing.contains(conclusion) || failing.contains(state) { return .failed }
        if inFlight.contains(status) || inFlight.contains(state) { return .running }
        if status == "COMPLETED" && conclusion.isEmpty && state.isEmpty { return .running }
        return .passed  // SUCCESS / NEUTRAL / SKIPPED
    }
}
