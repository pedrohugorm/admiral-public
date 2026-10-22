import Foundation

/// The Footprint panel for a selected group: every member's repos and tickets merged into one
/// deduplicated list, each row naming the members that touched it. Goals and checklists are
/// deliberately NOT merged — they stay per member (`memberExpandedByDefault`).
public struct GroupFootprint: Equatable, Sendable {
    /// One member's own footprint, as its tab carries it.
    public struct Member: Equatable, Sendable {
        public let key: UUID
        public let repos: [TouchedRepo]
        public let tickets: [TicketRef]

        public init(key: UUID, repos: [TouchedRepo], tickets: [TicketRef]) {
            self.key = key
            self.repos = repos
            self.tickets = tickets
        }
    }

    public struct RepoRow: Identifiable, Equatable, Sendable {
        public var id: String { repo.root }
        /// The repo as every member saw it together: branches unioned (first-seen order),
        /// files summed, PRs unioned by number, inside-root if it is for any member.
        public let repo: TouchedRepo
        /// The members that touched it, in member order.
        public let members: [UUID]
    }

    public struct TicketRow: Identifiable, Equatable, Sendable {
        public var id: String { ticket.key }
        public let ticket: TicketRef
        public let members: [UUID]
    }

    public let repos: [RepoRow]
    public let tickets: [TicketRow]

    public var isEmpty: Bool { repos.isEmpty && tickets.isEmpty }

    /// Merge the members' footprints. Rows touched by more members come first, then by name
    /// (repo folder name, then full path; ticket key) — an order that does not shuffle while
    /// a member keeps writing to a repo it already touched.
    public static func merge(_ members: [Member]) -> GroupFootprint {
        var repos: [String: TouchedRepo] = [:]
        var repoMembers: [String: [UUID]] = [:]
        var tickets: [String: TicketRef] = [:]
        var ticketMembers: [String: [UUID]] = [:]

        for member in members {
            for repo in member.repos {
                repos[repo.root] = repos[repo.root].map { combine($0, repo) } ?? repo
                attribute(member.key, to: repo.root, in: &repoMembers)
            }
            for ticket in member.tickets {
                // The first copy that carries a connector status wins; a bare key never
                // replaces an enriched one.
                if tickets[ticket.key]?.statusName == nil { tickets[ticket.key] = ticket }
                attribute(member.key, to: ticket.key, in: &ticketMembers)
            }
        }

        let repoRows = repos.values
            .map { RepoRow(repo: $0, members: repoMembers[$0.root] ?? []) }
            .sorted { a, b in
                if a.members.count != b.members.count { return a.members.count > b.members.count }
                let na = folderName(a.repo.root), nb = folderName(b.repo.root)
                if na != nb { return na.localizedStandardCompare(nb) == .orderedAscending }
                return a.repo.root < b.repo.root
            }
        let ticketRows = tickets.values
            .map { TicketRow(ticket: $0, members: ticketMembers[$0.key] ?? []) }
            .sorted { a, b in
                if a.members.count != b.members.count { return a.members.count > b.members.count }
                return a.ticket.key.localizedStandardCompare(b.ticket.key) == .orderedAscending
            }
        return GroupFootprint(repos: repoRows, tickets: ticketRows)
    }

    /// A member's goals section starts expanded only while it has an open goal; a member with
    /// nothing open (or nothing at all) starts collapsed.
    public static func memberExpandedByDefault(openGoals: Int) -> Bool { openGoals > 0 }

    private static func attribute(_ key: UUID, to id: String, in table: inout [String: [UUID]]) {
        if !(table[id] ?? []).contains(key) { table[id, default: []].append(key) }
    }

    private static func combine(_ a: TouchedRepo, _ b: TouchedRepo) -> TouchedRepo {
        var branches = a.branches
        for branch in b.branches where !branches.contains(branch) { branches.append(branch) }
        var prs = a.prs
        for pr in b.prs where !prs.contains(where: { $0.number == pr.number }) { prs.append(pr) }
        return TouchedRepo(root: a.root, branches: branches, filesWritten: a.filesWritten + b.filesWritten,
                           insideSessionRoot: a.insideSessionRoot || b.insideSessionRoot, prs: prs)
    }

    private static func folderName(_ root: String) -> String { (root as NSString).lastPathComponent }
}
