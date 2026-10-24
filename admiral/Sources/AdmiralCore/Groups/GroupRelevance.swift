import Foundation

/// Who an UNTAGGED group message is for. Each other member is scored 0...1 by a model that
/// reads the recent conversation; the message reaches every member at or above the threshold,
/// or the single highest scorer when none reaches it. The decisions live here, pure; the
/// service feeds them (`GroupService.post`).
public enum GroupRelevance {
    public static let defaultThreshold = 0.7
    /// How many of the latest messages the scorer reads.
    public static let contextMessages = 10

    /// The question put to the scorer for `callsign` about `message`, the newest in `log`.
    public static func prompt(group: String, callsign: String, log: [GroupMessage],
                              names: [UUID: String]) -> String {
        let recent = log.suffix(contextMessages).map { GroupPrompt.numbered($0, names: names) }
        return """
        You judge routing in a group chat between a user and coding agents. You are deciding \
        for @\(GroupPrompt.inline(callsign)) only.

        Conversation (oldest first, the last line is the new message):
        \(recent.joined(separator: "\n"))

        How likely is it that the new message is addressed to @\(GroupPrompt.inline(callsign)) \
        or needs a reply or action from them? A message to the whole group that touches their \
        work counts; a message clearly meant for someone else does not.
        Answer with JSON only: {"score": <number from 0 to 1>}
        """
    }

    /// The score in a scorer's output: the `score` of the first JSON object in it, else a bare
    /// number. Clamped to 0...1; nil when there is none.
    public static func parseScore(_ output: String) -> Double? {
        if let open = output.firstIndex(of: "{"), let close = output[open...].firstIndex(of: "}"),
           let data = String(output[open...close]).data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let score = (object["score"] as? NSNumber)?.doubleValue {
            return min(max(score, 0), 1)
        }
        guard let bare = Double(output.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return min(max(bare, 0), 1)
    }

    /// The members the message reaches, in `candidates` order. `scores` holds only the members
    /// the scorer answered for. With no answer at all, a user message reaches everyone (it is
    /// never lost) and an agent message reaches nobody.
    public static func select(candidates: [UUID], scores: [UUID: Double], threshold: Double,
                              fromHuman: Bool) -> [UUID] {
        let scored = candidates.filter { scores[$0] != nil }
        guard !scored.isEmpty else { return fromHuman ? candidates : [] }
        let hits = scored.filter { scores[$0]! >= threshold }
        if !hits.isEmpty { return hits }
        let best = scored.map { scores[$0]! }.max()!
        return scored.filter { scores[$0]! == best }.prefix(1).map { $0 }
    }
}
