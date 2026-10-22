import Foundation
import Combine

/// Groups, their logs and read cursors on disk under `<base>/groups/` (see `AdmiralPaths`).
///
/// Plain files, like `GoalsStore`, because a second process reads them: the `admiral-hook`
/// helper prepends a member's unseen messages to its prompt. The log is append-only JSON
/// lines whose line number is the message's `seq`.
@MainActor
public final class GroupStore: ObservableObject {
    /// Admiral's support dir; the files live under `<base>/groups/`.
    public let base: URL

    @Published public private(set) var groups: [ChatGroup] = []
    /// Loaded lazily per group; `append` keeps it in step with the file.
    @Published public private(set) var logs: [UUID: [GroupMessage]] = [:]

    /// The durable, human-readable copy of every conversation (`<claude home>/groups/`). Set by
    /// the app; nil = no copy (tests, or groups off).
    public var transcript: GroupTranscript?

    public init(base: URL) {
        self.base = base
        groups = GroupFiles.readGroups(base: base)
    }

    // MARK: - Lookup

    public func group(_ id: UUID) -> ChatGroup? { groups.first { $0.id == id } }

    /// A group by id string or by name (case-insensitive) — how a tool names one.
    public func group(ref: String) -> ChatGroup? {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: trimmed), let g = group(id) { return g }
        return groups.first { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    public func groups(containing member: UUID) -> [ChatGroup] {
        groups.filter { $0.members.contains(member) }
    }

    // MARK: - Membership

    @discardableResult
    public func create(name: String, members: [UUID]) -> Result<ChatGroup, GroupError> {
        let unique = members.reduce(into: [UUID]()) { if !$0.contains($1) { $0.append($1) } }
        guard unique.count >= 2 else { return .failure(.tooFewMembers) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let final = trimmed.isEmpty ? "New group" : trimmed
        guard group(ref: final) == nil else { return .failure(.nameTaken(final)) }
        let created = ChatGroup(name: final, members: unique)
        groups.append(created)
        saveGroups()
        return .success(created)
    }

    public func rename(_ id: UUID, to name: String) -> Result<Void, GroupError> {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return .failure(.noSuchGroup(id.uuidString)) }
        guard !trimmed.isEmpty else { return .success(()) }
        if let other = group(ref: trimmed), other.id != id { return .failure(.nameTaken(trimmed)) }
        let old = groups[index]
        groups[index].name = trimmed
        transcript?.renamed(from: old, to: groups[index])
        saveGroups()
        return .success(())
    }

    public func addMember(_ member: UUID, to id: UUID) -> Result<ChatGroup, GroupError> {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return .failure(.noSuchGroup(id.uuidString)) }
        guard !groups[index].members.contains(member) else { return .failure(.alreadyMember(member.uuidString)) }
        groups[index].members.append(member)
        saveGroups()
        return .success(groups[index])
    }

    /// Refused when it would leave fewer than 2 members.
    public func removeMember(_ member: UUID, from id: UUID) -> Result<ChatGroup, GroupError> {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return .failure(.noSuchGroup(id.uuidString)) }
        guard groups[index].members.contains(member) else { return .failure(.notAMember(member.uuidString)) }
        guard groups[index].members.count > 2 else { return .failure(.tooFewMembers) }
        groups[index].members.removeAll { $0 == member }
        saveGroups()
        removeCursor(member, group: id)
        return .success(groups[index])
    }

    /// A tab was closed: it leaves every group, which keeps its members otherwise. A group left
    /// with fewer than 2 stays (its history is still worth reading) and reports `isDegraded`.
    public func removeSession(_ session: UUID) {
        var changed = false
        for index in groups.indices where groups[index].members.contains(session) {
            groups[index].members.removeAll { $0 == session }
            removeCursor(session, group: groups[index].id)
            changed = true
        }
        if changed { saveGroups() }
    }

    public func isDegraded(_ group: ChatGroup) -> Bool { group.members.count < 2 }

    /// Deleting a group removes its working log and cursors, never its member tabs. The
    /// durable transcript copy stays: it is the record of what was said.
    public func delete(_ id: UUID) {
        groups.removeAll { $0.id == id }
        logs[id] = nil
        try? FileManager.default.removeItem(at: AdmiralPaths.groupLogFile(base: base, group: id))
        try? FileManager.default.removeItem(at: AdmiralPaths.groupCursorsFile(base: base, group: id))
        saveGroups()
    }

    // MARK: - Budget

    /// A human message: agents get a fresh budget.
    public func resetBudget(_ id: UUID) { mutate(id) { $0.spent = 0 } }

    /// An agent message was posted.
    public func spendBudget(_ id: UUID) { mutate(id) { $0.spent += 1 } }

    // MARK: - Log

    public func messages(_ id: UUID) -> [GroupMessage] {
        if let cached = logs[id] { return cached }
        let loaded = GroupFiles.readLog(base: base, group: id)
        logs[id] = loaded
        return loaded
    }

    @discardableResult
    public func append(to id: UUID, author: GroupMessage.Author, name: String, colorHex: String?,
                       symbol: String?, text: String, target: GroupMessage.Target,
                       reaction: String? = nil, reactionTo: Int? = nil,
                       at ts: Date = Date()) -> GroupMessage {
        let seq = (messages(id).last?.seq ?? 0) + 1
        let message = GroupMessage(seq: seq, ts: ts, author: author, name: name, colorHex: colorHex,
                                   symbol: symbol, text: text, target: target,
                                   reaction: reaction, reactionTo: reactionTo)
        let url = AdmiralPaths.groupLogFile(base: base, group: id)
        if var line = try? GroupFiles.encoder.encode(message) {
            line.append(0x0A)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: url, options: .atomic)
            }
        }
        logs[id, default: []].append(message)
        if let group = group(id) { transcript?.record(message, group: group, log: logs[id] ?? [message]) }
        return message
    }

    // MARK: - Cursors

    /// The last `seq` this member was given; 0 = nothing yet.
    public func cursor(_ member: UUID, group: UUID) -> Int {
        readCursors(group)[member.uuidString] ?? 0
    }

    public func setCursor(_ member: UUID, group: UUID, to seq: Int) {
        GroupFiles.setCursor(member, base: base, group: group, to: seq)
    }

    /// Messages after the member's cursor, not by the member itself.
    public func unseen(by member: UUID, in id: UUID) -> [GroupMessage] {
        let from = cursor(member, group: id)
        return messages(id).filter { $0.seq > from && $0.author != .member(member) }
    }

    private func removeCursor(_ member: UUID, group: UUID) {
        var all = readCursors(group)
        guard all.removeValue(forKey: member.uuidString) != nil else { return }
        writeCursors(all, group: group)
    }

    private func readCursors(_ group: UUID) -> [String: Int] {
        GroupFiles.readCursors(base: base, group: group)
    }

    private func writeCursors(_ all: [String: Int], group: UUID) {
        GroupFiles.writeCursors(all, base: base, group: group)
    }

    // MARK: - Persistence

    private func mutate(_ id: UUID, _ body: (inout ChatGroup) -> Void) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        body(&groups[index])
        saveGroups()
    }

    private func saveGroups() {
        guard let data = try? JSONEncoder().encode(groups) else { return }
        try? data.write(to: AdmiralPaths.groupsFile(base: base), options: .atomic)
    }
}
