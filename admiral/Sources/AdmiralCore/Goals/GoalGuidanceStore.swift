import Foundation

/// The house style for writing a goal, editable at
/// `~/Library/Application Support/Admiral/goal-guidance.txt`.
///
/// Plain text, not JSON or a template: it is prose that goes into a prompt, and the only
/// thing anyone ever wants to do with it is rewrite a sentence. An absent or blank file means
/// the built-in text, so deleting the file is the reset — there is no "is it customized?"
/// state to keep, and a future Admiral's better default reaches everyone who never edited it.
///
/// Read by two processes: the app (which serves it in the `set_goal` tool descriptions) and
/// the `admiral-hook` helper (which quotes the headline when inviting a session to set goals).
public enum GoalGuidance {
    /// What a good goal looks like. Two ways one goes bad, and the second is the dangerous
    /// one. A goal from the toolchain rather than the ask ("swift test passes") is provable
    /// but true of every task ever asked, so a list of them describes no particular work.
    ///
    /// A goal nothing can close is worse, because of what an open goal *does here*: this is
    /// not a notepad — while one stands the session is probed, nagged, and blocked from
    /// ending its turn. "Make auth robust" does not sit there unanswerable, it runs the
    /// session forever. Saying that cost out loud is what makes the rule stick.
    ///
    /// No subject is off-limits: a refactor that was asked for is a perfectly good goal, so
    /// the wording says "nothing it did not ask for" rather than naming kinds of work, which
    /// would read as a ban.
    ///
    /// "Must be able to FAIL" is the rule that stops the list becoming a transcript of the
    /// request. Left to itself a session writes one goal per bullet, each true the moment the
    /// code is typed; the slots are better spent on what breaks silently — the vacuous pass,
    /// the old path left running beside the new one, the enum one side emits and the other
    /// never reads. It is the same rubric this repo applies to goldens: one that cannot fail
    /// is worse than none, because it reads as coverage.
    public static let builtIn = """
        Each goal is one thing THIS REQUEST asked for, written as the outcome it will have \
        when it is done — in the words the request used. Take them from the ask itself: \
        whatever it wants is what to write, and nothing it did not ask for. Then name the \
        check that settles each one, in parentheses: the check PROVES the goal, it is never \
        the goal. Every goal must be able to FAIL. Do not transcribe the request bullet by \
        bullet; spend the slots on what would go wrong QUIETLY — the check that passes \
        because it found nothing to look at, the old path still live beside the new one, the \
        value one side emits and the other never reads, the "any" that was implemented as \
        "all". If a goal would still be true with the feature broken, it is not worth a slot; \
        if you cannot picture it failing, do not set it. Every goal must also be CLOSEABLE — \
        a moment where it is finished and nothing more is owed. While a goal is open this \
        session gets probed, nagged, and blocked from ending its turn, so a goal that can \
        always be pursued a little further keeps it working forever. If you cannot say what \
        would make you stop, it is not a goal. Good, asked to notify a session when its PR \
        moves: "a session is told once when its PR's checks change (two polls, one inject)". \
        Asked to refactor, the refactor's outcome is the goal: "the parser has one entry \
        point instead of four (grep shows one)". Bad, because nothing ever closes it: "make \
        auth robust", "improve performance", "keep the build green", "monitor the deploy". \
        Bad, because it is true of any task and so says nothing about what was asked: "run \
        the tests", "swift test passes", "the build succeeds". One outcome per goal: if it \
        needs an "and", make it two.
        """

    /// The limits, always appended — they are enforced in code, so they are not the user's
    /// to edit and an override that dropped them would advertise a lie.
    public static var limits: String {
        "At most \(SessionGoals.maxCount) goals, each at most \(SessionGoals.maxLength) characters."
    }

    public static func file(base: URL) -> URL {
        base.appendingPathComponent("goal-guidance.txt")
    }

    /// The effective guidance: the edited file, else the built-in. Whitespace-only counts as
    /// absent, so a file emptied in a text editor resets rather than blanking the prompt.
    public static func text(base: URL) -> String {
        let custom = (try? String(contentsOf: file(base: base), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (custom.isEmpty ? builtIn : custom) + " " + limits
    }

    public static func isCustomized(base: URL) -> Bool {
        let custom = (try? String(contentsOf: file(base: base), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !custom.isEmpty
    }

    /// Write an override, or remove it (nil / blank) to go back to the built-in.
    public static func set(_ text: String?, base: URL) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            try? FileManager.default.removeItem(at: file(base: base))
            return
        }
        try? Data(trimmed.utf8).write(to: file(base: base), options: .atomic)
    }
}
