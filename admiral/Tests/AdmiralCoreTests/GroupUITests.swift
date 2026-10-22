import XCTest
@testable import AdmiralCore

final class GroupUITests: XCTestCase {
    // MARK: - Working words

    func testWordHoldsForAPeriodThenAdvances() {
        let p = GroupWorkingWords.period
        XCTAssertEqual(GroupWorkingWords.index(elapsed: 0), 0)
        XCTAssertEqual(GroupWorkingWords.index(elapsed: p - 0.01), 0)
        XCTAssertEqual(GroupWorkingWords.index(elapsed: p), 1)
        XCTAssertEqual(GroupWorkingWords.index(elapsed: p * 2.5), 2)
        XCTAssertEqual(GroupWorkingWords.word(elapsed: 0), GroupWorkingWords.words[0] + "…")
    }

    func testWordWrapsAroundTheList() {
        let n = GroupWorkingWords.words.count
        XCTAssertEqual(GroupWorkingWords.index(elapsed: GroupWorkingWords.period * Double(n)), 0)
        XCTAssertEqual(GroupWorkingWords.index(elapsed: GroupWorkingWords.period * Double(n + 1)), 1)
        XCTAssertEqual(GroupWorkingWords.index(elapsed: -5), 0)
    }

    func testElapsedLabelMatchesChatView() {
        XCTAssertEqual(GroupWorkingWords.elapsedLabel(42), "42s")
        XCTAssertEqual(GroupWorkingWords.elapsedLabel(65), "1m 05s")
        XCTAssertEqual(GroupWorkingWords.elapsedLabel(-3), "0s")
    }

    // MARK: - Mention picker

    private let api = GroupMentionPicker.Candidate(name: "api-fix", id: UUID())
    private let web = GroupMentionPicker.Candidate(name: "web-ui", id: UUID())
    private let qa = GroupMentionPicker.Candidate(name: "qa", id: UUID())
    private var members: [GroupMentionPicker.Candidate] { [api, web, qa] }

    func testQueryOpensOnAnAtThatStartsAWord() {
        XCTAssertEqual(GroupMentionPicker.query(in: "@"), .init(offset: 0, partial: ""))
        XCTAssertEqual(GroupMentionPicker.query(in: "Looks good. @w"), .init(offset: 12, partial: "w"))
        XCTAssertEqual(GroupMentionPicker.query(in: "hi\n@api-f"), .init(offset: 3, partial: "api-f"))
    }

    func testQueryStaysClosedMidWordAndAfterASpace() {
        XCTAssertNil(GroupMentionPicker.query(in: "mail me at sam@ex"))
        XCTAssertNil(GroupMentionPicker.query(in: "@api "))
        XCTAssertNil(GroupMentionPicker.query(in: "no mention"))
        XCTAssertNil(GroupMentionPicker.query(in: ""))
    }

    func testEmptyPartialListsEveryMemberThenAll() {
        XCTAssertEqual(GroupMentionPicker.candidates("", members: members).map(\.name),
                       ["api-fix", "web-ui", "qa", "all"])
    }

    func testPrefixMatchesRankBeforeContainsAndCaseIsIgnored() {
        let more = members + [.init(name: "deploy-qa", id: UUID())]
        XCTAssertEqual(GroupMentionPicker.candidates("QA", members: more).map(\.name), ["qa", "deploy-qa"])
        XCTAssertEqual(GroupMentionPicker.candidates("a", members: members).map(\.name), ["api-fix", "qa", "all"])
        XCTAssertEqual(GroupMentionPicker.candidates("zz", members: members), [])
        XCTAssertTrue(GroupMentionPicker.candidates("al", members: members).last!.isAll)
    }

    func testInsertReplacesTheQueryWithTheHandleAndASpace() {
        let text = "Looks good. @we"
        let q = GroupMentionPicker.query(in: text)!
        XCTAssertEqual(GroupMentionPicker.insert("web-ui", into: text, at: q), "Looks good. @web-ui ")
        XCTAssertEqual(GroupMentionPicker.insert("all", into: "@", at: .init(offset: 0, partial: "")), "@all ")
    }

    func testMoveWrapsBothWays() {
        XCTAssertEqual(GroupMentionPicker.move(0, by: -1, count: 4), 3)
        XCTAssertEqual(GroupMentionPicker.move(3, by: 1, count: 4), 0)
        XCTAssertEqual(GroupMentionPicker.move(1, by: 1, count: 4), 2)
        XCTAssertEqual(GroupMentionPicker.move(2, by: 1, count: 0), 0)
    }

    // MARK: - Mention coloring

    func testOnlyMemberAndAllTokensAreColored() {
        let text = "@web-ui and @API-fix, mail a@b.c, @nobody, @all."
        let tokens = GroupMention.mentions(text, names: ["web-ui", "api-fix"])
        XCTAssertEqual(tokens.map(\.name), ["web-ui", "API-fix", "all"])
        XCTAssertEqual(tokens.first, .init(offset: 0, length: 7, name: "web-ui"))
        // The trailing period is punctuation, not part of the handle.
        XCTAssertEqual(tokens.last?.length, 4)
    }

    // MARK: - Tile

    func testTileShowsAtMostFourMembersInOrder() {
        XCTAssertEqual(GroupTile.cells([1, 2, 3, 4, 5, 6]), [1, 2, 3, 4])
        XCTAssertEqual(GroupTile.cells([1, 2]), [1, 2, nil, nil])
        XCTAssertEqual(GroupTile.cells([Int]()), [nil, nil, nil, nil])
    }

    // MARK: - Drop zone

    func testMiddleBandOfATabOnATabProposesAGroup() {
        func zone(_ y: Double, _ dragged: Bool = true, _ target: Bool = true, _ on: Bool = true) -> SidebarDropZone {
            SidebarDropZone.zone(y: y, height: 100, draggedIsTab: dragged, targetIsTab: target, groupsEnabled: on)
        }
        XCTAssertEqual(zone(50), .group)
        XCTAssertEqual(zone(31), .group)
        XCTAssertEqual(zone(69), .group)
        XCTAssertEqual(zone(30), .reorder)
        XCTAssertEqual(zone(70), .reorder)
        XCTAssertEqual(zone(10), .reorder)
        XCTAssertEqual(zone(90), .reorder)
        XCTAssertEqual(zone(50, false), .reorder)
        XCTAssertEqual(zone(50, true, false), .reorder)
        XCTAssertEqual(zone(50, true, true, false), .reorder)
    }

    // MARK: - Flag gate

    func testFlagOffShowsNoGroupAffordance() {
        let me = UUID()
        let groups = [ChatGroup(name: "g", members: [me, UUID()])]
        XCTAssertFalse(GroupUIGate.footer(groupsEnabled: false, apiServer: true).contains(.newGroup))
        XCTAssertEqual(GroupUIGate.tabMenu(groupsEnabled: false, member: me, groups: groups), [])
    }

    func testFlagOnShowsNewGroupBesideTheNewTabActions() {
        XCTAssertEqual(GroupUIGate.footer(groupsEnabled: true, apiServer: false),
                       [.newClaudeCode, .newBash, .newGroup, .schedules, .settings])
    }

    func testTabMenuOffersOnlyGroupsTheTabIsNotIn() {
        let me = UUID()
        let mine = ChatGroup(name: "mine", members: [me, UUID()])
        let other = ChatGroup(name: "other", members: [UUID(), UUID()])
        XCTAssertEqual(GroupUIGate.tabMenu(groupsEnabled: true, member: me, groups: [mine, other]),
                       [.newGroupWithTab, .addToGroup([other.id])])
        XCTAssertEqual(GroupUIGate.tabMenu(groupsEnabled: true, member: me, groups: [mine]), [.newGroupWithTab])
    }

    // MARK: - Seen cursor

    private func message(_ seq: Int, human: Bool, at ts: Date = Date()) -> GroupMessage {
        GroupMessage(seq: seq, ts: ts, author: human ? .human : .member(UUID()), name: "n",
                     text: "t", target: .everyone)
    }

    func testUnreadIsAMemberMessagePastTheCursor() {
        let log = [message(1, human: true), message(2, human: false)]
        XCTAssertTrue(GroupSeenCursor.isUnread(log, seen: 1))
        XCTAssertFalse(GroupSeenCursor.isUnread(log, seen: 2))
        XCTAssertFalse(GroupSeenCursor.isUnread([message(3, human: true)], seen: 2))
        XCTAssertFalse(GroupSeenCursor.isUnread([], seen: 0))
    }

    func testSeenCursorPersistsAndNeverMovesBack() {
        let suite = "admiral.tests.groupseen.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let g = UUID()
        let cursor = GroupSeenCursor(defaults: defaults)
        XCTAssertEqual(cursor.seen(g), 0)
        cursor.markSeen(g, through: 5)
        cursor.markSeen(g, through: 3)
        XCTAssertEqual(GroupSeenCursor(defaults: defaults).seen(g), 5)
    }

    // MARK: - Day breaks

    func testDayBreaksMarkTheFirstMessageOfEachDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let day1 = Date(timeIntervalSince1970: 86_400 * 100 + 3600)
        let log = [message(1, human: true, at: day1), message(2, human: false, at: day1.addingTimeInterval(60)),
                   message(3, human: false, at: day1.addingTimeInterval(86_400))]
        XCTAssertEqual(GroupTimeline.dayBreaks(log, calendar: cal), [1, 3])
    }
}
