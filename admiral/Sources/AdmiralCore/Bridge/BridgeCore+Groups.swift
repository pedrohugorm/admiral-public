import Foundation

/// The `group_*` tools: plain-text answers over `GroupService`. They exist only while
/// `groups` is set (the app sets it while `features.groups` is on); `MCPServer` neither lists
/// nor dispatches them otherwise, so the guards below are for direct callers.
///
/// The caller is its session token, like every station tool; members are named by callsign
/// (any case), resolved against `GroupService.peers()`.
extension BridgeCore {
    private static let noGroups = BridgeResult.failure(GroupError.disabled.description)

    /// `group_say`: post as the calling tab. Recipients and refusals are `GroupService.post`'s.
    public func groupSay(fromToken token: String, group: String, text: String, to: [String] = []) -> BridgeResult {
        guard let groups else { return Self.noGroups }
        guard let me = manager.session(forToken: token) else { return .failure("error: unknown caller") }
        switch groups.post(group: group, from: .member(Self.memberKey(me)), text: text, to: to) {
        case let .success(result): return .success(result.summary)
        case let .failure(error): return .failure(error.description)
        }
    }

    /// `group_react`: a 👀 👍 👎 or ✅ on message `#message`, instead of a message of its own.
    public func groupReact(fromToken token: String, group: String, message: Int?, emoji: String) -> BridgeResult {
        guard let groups else { return Self.noGroups }
        guard let me = manager.session(forToken: token) else { return .failure("error: unknown caller") }
        guard let message else { return .failure("message is required: the #id of the message to react to") }
        switch groups.react(group: group, member: Self.memberKey(me), to: message, emoji: emoji) {
        case let .success(summary): return .success(summary)
        case let .failure(error): return .failure(error.description)
        }
    }

    /// `group_log`: up to `limit` messages after `since`, oldest first, one `#seq` line each.
    /// Without `since`, the newest `limit`. Seqs are line numbers, so the paging pointers are
    /// plain arithmetic. Only a member reads a group's log.
    public func groupLog(fromToken token: String, group ref: String, since: Int? = nil, limit: Int = 50) -> BridgeResult {
        guard let groups else { return Self.noGroups }
        guard let me = manager.session(forToken: token) else { return .failure("error: unknown caller") }
        guard let group = groups.store.group(ref: ref) else { return .failure(GroupError.noSuchGroup(ref).description) }
        guard group.members.contains(Self.memberKey(me)) else { return .failure(GroupError.notAMember(me.displayTitle).description) }
        let all = groups.store.messages(group.id)
        let limit = max(limit, 1)
        let from = max(since ?? (all.count - limit), 0)
        let after = all.filter { $0.seq > from }
        let shown = after.prefix(limit)
        guard let first = shown.first, let last = shown.last else { return .success("(no messages after #\(from))") }
        var lines: [String] = []
        if first.seq > 1 {
            lines.append("(\(first.seq - 1) earlier — group_log since=\(max(first.seq - 1 - limit, 0)))")
        }
        let byKey = Dictionary(groups.peers().map { ($0.id, $0.callsign) }, uniquingKeysWith: { a, _ in a })
        lines += shown.map { GroupPrompt.numbered($0, names: byKey) }
        if after.count > shown.count {
            lines.append("(\(after.count - shown.count) more — group_log since=\(last.seq))")
        }
        return .success(lines.joined(separator: "\n"))
    }

    /// `group_list`: the caller's groups with every member's state and whether it is paused.
    public func groupList(fromToken token: String) -> BridgeResult {
        guard let groups else { return Self.noGroups }
        guard let me = manager.session(forToken: token) else { return .failure("error: unknown caller") }
        let mine = groups.store.groups(containing: Self.memberKey(me))
        guard !mine.isEmpty else { return .success("(you are in no groups)") }
        let peers = peerIndex(groups)
        return .success(mine.map { group in
            let members = group.members.map { id in
                peers[id].map { "@\($0.callsign) (\($0.status.rawValue))" } ?? "(closed tab)"
            }
            var line = "\(GroupPrompt.inline(group.name)) — \(members.joined(separator: ", "))"
            if group.isPaused { line += " — paused (agents used their budget; waiting on the user)" }
            return line
        }.joined(separator: "\n"))
    }

    /// `group_create`: a new group of the named tabs. The caller is not added unless named.
    public func groupCreate(fromToken token: String, name: String, members: [String]) -> BridgeResult {
        guard let groups else { return Self.noGroups }
        guard manager.session(forToken: token) != nil else { return .failure("error: unknown caller") }
        var ids: [UUID] = []
        for callsign in members {
            switch resolve(callsign, groups) {
            case let .success(peer): ids.append(peer.id)
            case let .failure(message): return message
            }
        }
        switch groups.store.create(name: name, members: ids) {
        case let .failure(error): return .failure(error.description)
        case let .success(group):
            groups.writeCallsigns()
            return .success("created group \"\(group.name)\" with \(names(group.members, groups))")
        }
    }

    public func groupAddMember(fromToken token: String, group ref: String, member: String) -> BridgeResult {
        changeMembership(token: token, group: ref, member: member) { store, id, group in
            store.addMember(id, to: group)
        } done: { "added @\($0) to" }
    }

    /// Refused when it would leave fewer than 2 members (the store's message says so).
    public func groupRemoveMember(fromToken token: String, group ref: String, member: String) -> BridgeResult {
        changeMembership(token: token, group: ref, member: member) { store, id, group in
            store.removeMember(id, from: group)
        } done: { "removed @\($0) from" }
    }

    /// `group_rename`: only a member renames its group. The transcript file follows the name.
    public func groupRename(fromToken token: String, group ref: String, name: String) -> BridgeResult {
        switch ownGroup(token: token, ref: ref) {
        case let .failure(message): return message
        case let .success((groups, group)):
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure("name is empty")
            }
            switch groups.store.rename(group.id, to: name) {
            case .success:
                let now = groups.store.group(group.id)?.name ?? name
                return .success("renamed \"\(group.name)\" to \"\(now)\"")
            case let .failure(error): return .failure(error.description)
            }
        }
    }

    /// `group_delete`: only a member deletes its group. The group and its working log go; its
    /// tabs stay open and the durable transcript copy is kept.
    public func groupDelete(fromToken token: String, group ref: String) -> BridgeResult {
        switch ownGroup(token: token, ref: ref) {
        case let .failure(message): return message
        case let .success((groups, group)):
            groups.store.delete(group.id)
            return .success("deleted group \"\(group.name)\" — its tabs stay open and its transcript is kept")
        }
    }

    // MARK: - Helpers

    private enum Owned { case success((GroupService, ChatGroup)), failure(BridgeResult) }

    /// The group named by `ref`, when groups are on and the caller is one of its members.
    private func ownGroup(token: String, ref: String) -> Owned {
        guard let groups else { return .failure(Self.noGroups) }
        guard let me = manager.session(forToken: token) else { return .failure(.failure("error: unknown caller")) }
        guard let group = groups.store.group(ref: ref) else {
            return .failure(.failure(GroupError.noSuchGroup(ref).description))
        }
        guard group.members.contains(Self.memberKey(me)) else {
            return .failure(.failure(GroupError.notAMember(me.displayTitle).description))
        }
        return .success((groups, group))
    }

    /// A tab's key in groups: its claude session id (stable across launches, and all the
    /// prompt hook knows), else the tab id for a tab that has none.
    static func memberKey(_ session: AgentSession) -> UUID {
        session.claudeSessionID.flatMap(UUID.init(uuidString:)) ?? session.id
    }

    private func changeMembership(token: String, group ref: String, member: String,
                                  _ change: (GroupStore, UUID, UUID) -> Result<ChatGroup, GroupError>,
                                  done verb: (String) -> String) -> BridgeResult {
        // Only a member changes who is in a group, as for rename and delete.
        let groups: GroupService, group: ChatGroup
        switch ownGroup(token: token, ref: ref) {
        case let .failure(message): return message
        case let .success((service, owned)): (groups, group) = (service, owned)
        }
        let peer: GroupPeer
        switch resolve(member, groups) {
        case let .success(found): peer = found
        case let .failure(message): return message
        }
        switch change(groups.store, peer.id, group.id) {
        case let .success(updated):
            groups.writeCallsigns()
            return .success("\(verb(peer.callsign)) \"\(updated.name)\" — members: \(names(updated.members, groups))")
        // The store names members by tab id; the caller named a callsign, so answer in those.
        case .failure(.alreadyMember): return .failure(GroupError.alreadyMember(peer.callsign).description)
        case .failure(.notAMember): return .failure(GroupError.notAMember(peer.callsign).description)
        case let .failure(error): return .failure(error.description)
        }
    }

    private enum Resolved { case success(GroupPeer), failure(BridgeResult) }

    private func resolve(_ raw: String, _ groups: GroupService) -> Resolved {
        let callsign = raw.hasPrefix("@") ? String(raw.dropFirst()) : raw
        let peers = groups.peers()
        if let peer = peers.first(where: { $0.callsign.caseInsensitiveCompare(callsign) == .orderedSame }) {
            return .success(peer)
        }
        let known = peers.map { "@\($0.callsign)" }.sorted().joined(separator: ", ")
        return .failure(.failure("no tab @\(callsign); tabs: \(known.isEmpty ? "(none)" : known)"))
    }

    private func peerIndex(_ groups: GroupService) -> [UUID: GroupPeer] {
        Dictionary(groups.peers().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func names(_ ids: [UUID], _ groups: GroupService) -> String {
        let peers = peerIndex(groups)
        return ids.map { peers[$0].map { "@\($0.callsign)" } ?? "(closed tab)" }.joined(separator: ", ")
    }
}
