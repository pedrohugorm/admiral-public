import Foundation

/// Decides what a session should be told about its pull requests. Pure — no `gh`, no clock,
/// no session — so every rule below is settled by a unit test rather than by a CI run.
public enum PRWatchMachine {
    public struct Tick {
        /// What the session was polled for and told before, or nil the first time ever.
        public let stored: PRWatchState?
        /// This cycle's poll, by repo root. Only roots that were actually fetched appear —
        /// an absent root keeps whatever was stored for it.
        public let fresh: [String: [PRDigest]]
        /// Can text typed into the session reach claude as a message? Busy or idle both can —
        /// claude takes a message mid-turn. When it cannot (a dialog is open, or claude is not
        /// running) the news is held: the digest stays unannounced, so the next cycle
        /// re-detects it (and folds in anything else that moved meanwhile).
        public let canType: Bool
        public let now: Date

        public init(stored: PRWatchState?, fresh: [String: [PRDigest]], canType: Bool, now: Date) {
            self.stored = stored
            self.fresh = fresh
            self.canType = canType
            self.now = now
        }
    }

    public struct Result: Equatable {
        public var state: PRWatchState
        public var effects: [Effect]
    }

    public enum Effect: Equatable {
        case inject(String)
    }

    public static func step(_ tick: Tick) -> Result {
        var state = tick.stored ?? PRWatchState()
        state.checkedAt = tick.now

        var changes: [PRChange] = []
        for root in tick.fresh.keys.sorted() {
            let digests = tick.fresh[root] ?? []
            // Which PRs this session had already polled, read BEFORE the overwrite below:
            // "first sighting" is what we have *seen*, not what we managed to *say*.
            let seenBefore = Set((state.repos[root] ?? []).map(\.number))
            state.repos[root] = digests
            for digest in digests {
                let key = PRWatchState.key(root: root, number: digest.number)
                let before = state.announced[key]
                guard before?.signature != digest.signature else { continue }
                // A PR nobody ever announced, already merged, is history rather than news —
                // that is what an old PR on `main` looks like on a session's first poll.
                // Record it so it stays quiet forever after.
                //
                // `seenBefore` is what keeps a *held* PR out of this branch: a change we could
                // not deliver leaves `announced` empty, so without it a PR held while mergeable
                // and merged before the next chance to speak would be filed as history and
                // silently lost — the loudest news of all, swallowed.
                guard before != nil || seenBefore.contains(digest.number)
                        || digest.state != .merged else {
                    state.announced[key] = digest
                    continue
                }
                changes.append(PRChange(root: root, digest: digest,
                                        deltas: digest.deltas(since: before)))
            }
        }

        guard !changes.isEmpty else { return Result(state: state, effects: []) }
        guard tick.canType else {
            // Held: `repos` still advances (so `pr_status` is current), `announced` does not.
            return Result(state: state, effects: [])
        }
        for change in changes {
            state.announced[PRWatchState.key(root: change.root, number: change.digest.number)] = change.digest
        }
        return Result(state: state, effects: [.inject(PRWatchMessage.text(for: changes))])
    }
}
