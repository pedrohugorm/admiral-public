import Foundation

/// A member woken by a group message that ends its turn without calling `group_say` gets that
/// turn's final reply posted to the group on its behalf. The decisions live here, pure; the
/// service only feeds them (`GroupService.postFinishedTurns`).
public enum GroupAutoPost {
    /// The `source` a group wake is typed with, so the chat ledger tells it from the user's
    /// own prompts (`SessionManager.deliver(_:text:source:)`).
    public static let promptSource = "group"
    /// The most of a reply that is posted; the rest is cut with `truncationMarker`.
    public static let maxChars = 4000
    public static let truncationMarker = "\n… (reply truncated)"

    public enum Skip: Equatable, Sendable {
        case noReply, passed, alreadyPosted, groupGone, notAMember
    }

    public enum Decision: Equatable, Sendable {
        case post(String)
        case skip(Skip)
    }

    /// What to do with `reply`, the final message of a turn that `member` took after a wake
    /// that delivered up to `wakeSeq` of `group` (nil = deleted). `messages` is that group's log.
    /// (The feature flag is the service's gate: with it off no wake is ever recorded.)
    public static func decide(reply: String?, member: UUID, wakeSeq: Int, group: ChatGroup?,
                              messages: [GroupMessage]) -> Decision {
        guard let group else { return .skip(.groupGone) }
        guard group.members.contains(member) else { return .skip(.notAMember) }
        let body = (reply ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return .skip(.noReply) }
        guard body != GroupService.passToken else { return .skip(.passed) }
        // It called group_say during the turn: that was its answer.
        if messages.contains(where: { $0.seq > wakeSeq && $0.author == .member(member) }) {
            return .skip(.alreadyPosted)
        }
        return .post(truncated(body))
    }

    public static func truncated(_ text: String) -> String {
        text.count > maxChars ? String(text.prefix(maxChars)) + truncationMarker : text
    }

    /// The last reply of the turn the group wake started, read from the session's chat ledger
    /// (the Stop hook writes `last_assistant_message` there: the agent's final text, never tool
    /// output). Nil when there is no reply yet, or when ANY other prompt came after the wake:
    /// the user (or another Admiral feature) typed into the tab, so the reply is not the group's.
    ///
    /// The turn starts after the first group prompt at or after `since` (the ledger stamps
    /// whole seconds, so `since` is floored; this skips a previous turn's reply written in the
    /// same second). With no group prompt in the ledger it starts at the next whole second.
    public static func finalReply(ledger: [ChatEvent], since: Date) -> String? {
        let floor = Date(timeIntervalSince1970: since.timeIntervalSince1970.rounded(.down))
        func at(_ event: ChatEvent) -> Date { ChatHistory.date(event.ts) ?? .distantPast }
        let turn: ArraySlice<ChatEvent>
        if let wake = ledger.firstIndex(where: { isGroupPrompt($0) && at($0) >= floor }) {
            turn = ledger[(wake + 1)...]
        } else {
            turn = ledger.drop(while: { at($0) < floor.addingTimeInterval(1) })
        }
        var reply: String?
        for event in turn {
            switch event.kind {
            case .prompt where !isGroupPrompt(event): return nil
            case .reply: reply = event.text
            default: continue
            }
        }
        return reply
    }

    /// A wake's prompt: tagged by `deliver`'s source, or (when the tagging did not match, e.g.
    /// a socket-delivered message the hook saw wrapped) recognized by `GroupPrompt`'s header,
    /// which nobody types by hand.
    static func isGroupPrompt(_ event: ChatEvent) -> Bool {
        event.kind == .prompt
            && (event.source == promptSource || (event.text ?? "").contains("[group \""))
    }
}
