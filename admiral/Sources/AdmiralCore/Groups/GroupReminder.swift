import Foundation

/// The group half of the `UserPromptSubmit` hook: a member prompted any way other than a group
/// wake (the user typing, a hail, a schedule) gets the group messages it has not seen, once.
///
/// Runs in the `admiral-hook` helper, a separate process with no `GroupStore`, so it reads the
/// plain files under `<base>/groups/` directly. A member's key is its claude session id, which
/// is exactly what the hook payload carries.
///
/// The cursor is written BEFORE the context is returned, like the goals `.reminded` marker: a
/// failed write leaves the cursor behind and the messages are sent again next prompt, rather
/// than being marked seen and never arriving. Admiral's own wake prompt advances the same
/// cursor when it types the messages, so a woken member gets nothing twice.
public enum GroupReminder {
    /// After `/clear` or compaction the next prompt re-reads this many of the latest messages.
    public static let digest = 5

    /// The context to put before this prompt, or nil. A no-op unless `config.json` at `base`
    /// turns `features.groups` on and the session is in a group.
    public static func context(payload: Data, base: URL) -> String? {
        guard let (sessionID, member) = member(in: payload, base: base) else { return nil }
        let marker = AdmiralPaths.groupMembershipSentFile(base: base, session: sessionID)
        let groups = GroupFiles.readGroups(base: base).filter { $0.members.contains(member) }
        guard !groups.isEmpty else {
            try? FileManager.default.removeItem(at: marker)
            return nil
        }
        let names = GroupFiles.readCallsigns(base: base)
        // Names on one line, so a group or callsign carrying a newline cannot add a line.
        func name(_ id: UUID) -> String {
            GroupPrompt.inline(names[id.uuidString] ?? String(id.uuidString.prefix(8)).lowercased())
        }

        var parts: [String] = []
        let membership = groups.map { group in
            let others = group.members.filter { $0 != member }.map { "@" + name($0) }
            return "You are @\(name(member)) in group \"\(GroupPrompt.inline(group.name))\" with \(others.joined(separator: ", "))."
        }.joined(separator: "\n")
        if (try? String(contentsOf: marker, encoding: .utf8)) != membership {
            try? membership.write(to: marker, atomically: true, encoding: .utf8)
            parts.append(membership)
        }

        for group in groups {
            let log = GroupFiles.readLog(base: base, group: group.id)
            let cursor = GroupFiles.readCursors(base: base, group: group.id)[member.uuidString] ?? 0
            // A member's own messages are never news to it.
            let unseen = log.filter { $0.seq > cursor && $0.author != .member(member) }
            guard !unseen.isEmpty, let last = log.last else { continue }
            GroupFiles.setCursor(member, base: base, group: group.id, to: last.seq)
            let byKey = Dictionary(group.members.map { ($0, name($0)) }, uniquingKeysWith: { a, _ in a })
            parts.append(GroupPrompt.text(group: group.name, members: group.members.map(name), messages: unseen,
                                          viewer: member, names: byKey))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// `SessionStart` (clear|compact): the earlier messages left context, so every cursor
    /// moves back to the last `digest` messages (never forward) and the membership line is
    /// sent again.
    public static func rewind(payload: Data, base: URL) {
        guard let (sessionID, member) = member(in: payload, base: base) else { return }
        try? FileManager.default.removeItem(at: AdmiralPaths.groupMembershipSentFile(base: base, session: sessionID))
        for group in GroupFiles.readGroups(base: base) where group.members.contains(member) {
            let last = GroupFiles.readLog(base: base, group: group.id).last?.seq ?? 0
            let cursor = GroupFiles.readCursors(base: base, group: group.id)[member.uuidString] ?? 0
            GroupFiles.setCursor(member, base: base, group: group.id, to: min(cursor, max(last - digest, 0)))
        }
    }

    /// The flag gate, read from disk because the helper has no app to ask. A missing
    /// `config.json` is off — and is not created, which `AdmiralConfigStore.load` would do.
    public static func isEnabled(base: URL) -> Bool {
        let url = base.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return AdmiralConfigStore.load(from: url).features.groups
    }

    private static func member(in payload: Data, base: URL) -> (String, UUID)? {
        guard isEnabled(base: base),
              let sessionID = GoalsReminder.sessionID(in: payload),
              let member = UUID(uuidString: sessionID) else { return nil }
        return (sessionID, member)
    }
}
