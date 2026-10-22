import Foundation

/// How many times this session's Stop has already been blocked for a goal review, since the
/// user last said something.
///
/// The budget exists because a Stop block resumes the turn: with no limit, a session that
/// simply cannot finish a goal right now would be blocked, resume, stop, be blocked again —
/// forever, with the user unable to get a word in. One block per prompt is enough to force
/// the review; after that the turn ends and the user is back in control.
///
/// Reset by `UserPromptSubmit`, so every new instruction re-arms the review.
public enum GoalReviewLedger {
    public static let maxBlocksPerPrompt = 1

    private static func url(base: URL, token: String) -> URL {
        AdmiralPaths.sessionDir(base: base, token: token)
            .appendingPathComponent("goal-review.json")
    }

    private struct Ledger: Codable { var blocks: Int }

    /// Records a block and reports whether it may be issued. Consuming and asking are one
    /// call so the counter cannot be read without being spent.
    public static func consumeBlock(base: URL, token: String) -> Bool {
        let url = url(base: base, token: token)
        let current = (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode(Ledger.self, from: $0) }?.blocks ?? 0
        guard current < maxBlocksPerPrompt else { return false }
        if let data = try? JSONEncoder().encode(Ledger(blocks: current + 1)) {
            try? data.write(to: url, options: .atomic)
        }
        return true
    }

    /// A new prompt — the session gets its review budget back.
    public static func reset(base: URL, token: String) {
        try? FileManager.default.removeItem(at: url(base: base, token: token))
    }
}
