import XCTest
@testable import AdmiralCore

final class GroupFootprintTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID()

    private func repo(_ root: String, _ branches: [String] = ["main"], files: Int = 1,
                      inside: Bool = true, prs: [Int] = []) -> TouchedRepo {
        TouchedRepo(root: root, branches: branches, filesWritten: files, insideSessionRoot: inside,
                    prs: prs.map { PRStatus(number: $0, title: "PR \($0)", url: "u\($0)", isMerged: false,
                                            canMerge: false, approvals: 0, checksPassed: 0,
                                            checksRunning: 0, checksFailed: 0) })
    }

    func testEmptyGroupIsEmpty() {
        XCTAssertTrue(GroupFootprint.merge([]).isEmpty)
        XCTAssertTrue(GroupFootprint.merge([.init(key: a, repos: [], tickets: [])]).isEmpty)
    }

    func testSharedRepoAppearsOnceWithBothMembers() {
        let merged = GroupFootprint.merge([
            .init(key: a, repos: [repo("/w/shop")], tickets: []),
            .init(key: b, repos: [repo("/w/shop"), repo("/w/infra")], tickets: []),
        ])
        XCTAssertEqual(merged.repos.map(\.repo.root), ["/w/shop", "/w/infra"])
        XCTAssertEqual(merged.repos[0].members, [a, b])
        XCTAssertEqual(merged.repos[1].members, [b])
    }

    func testMemberWithNothingIsAttributedNothing() {
        let merged = GroupFootprint.merge([
            .init(key: a, repos: [repo("/w/shop")], tickets: [TicketRef(key: "AB-1")]),
            .init(key: c, repos: [], tickets: []),
        ])
        XCTAssertEqual(merged.repos.map(\.members), [[a]])
        XCTAssertEqual(merged.tickets.map(\.members), [[a]])
    }

    func testDifferingBranchesAndPRsMergeIntoOneRow() {
        let merged = GroupFootprint.merge([
            .init(key: a, repos: [repo("/w/shop", ["main", "fix/A"], files: 2, inside: false, prs: [7])], tickets: []),
            .init(key: b, repos: [repo("/w/shop", ["fix/B", "main"], files: 3, inside: true, prs: [7, 9])], tickets: []),
        ])
        XCTAssertEqual(merged.repos.count, 1)
        let row = merged.repos[0].repo
        XCTAssertEqual(row.branches, ["main", "fix/A", "fix/B"])
        XCTAssertEqual(row.prs.map(\.number), [7, 9])
        XCTAssertEqual(row.filesWritten, 5)
        XCTAssertTrue(row.insideSessionRoot)
    }

    func testOrderingMoreMembersFirstThenName() {
        let merged = GroupFootprint.merge([
            .init(key: a, repos: [repo("/w/zeta"), repo("/w/beta"), repo("/x/alpha")], tickets: []),
            .init(key: b, repos: [repo("/w/zeta"), repo("/w/alpha")], tickets: []),
        ])
        XCTAssertEqual(merged.repos.map(\.repo.root), ["/w/zeta", "/w/alpha", "/x/alpha", "/w/beta"])
    }

    func testTicketsDedupKeepEnrichedCopyAndOrder() {
        let merged = GroupFootprint.merge([
            .init(key: a, repos: [], tickets: [TicketRef(key: "AB-10"), TicketRef(key: "AB-2")]),
            .init(key: b, repos: [], tickets: [TicketRef(key: "AB-10", statusName: "In Progress",
                                                         statusCategory: .inProgress)]),
            .init(key: a, repos: [], tickets: [TicketRef(key: "AB-10")]),
        ])
        XCTAssertEqual(merged.tickets.map(\.ticket.key), ["AB-10", "AB-2"])
        XCTAssertEqual(merged.tickets[0].members, [a, b])
        XCTAssertEqual(merged.tickets[0].ticket.statusName, "In Progress")
    }

    func testMemberExpandedOnlyWithOpenGoals() {
        XCTAssertTrue(GroupFootprint.memberExpandedByDefault(openGoals: 2))
        XCTAssertFalse(GroupFootprint.memberExpandedByDefault(openGoals: 0))
    }
}
