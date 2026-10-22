import XCTest
@testable import AdmiralCore

final class GroupAsksTests: XCTestCase {
    private let api = UUID(), web = UUID(), qa = UUID()
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func iso(_ offset: TimeInterval) -> String { GroupTimeline.iso(t0.addingTimeInterval(offset)) }

    private func message(_ seq: Int, at offset: TimeInterval, _ text: String = "m") -> GroupMessage {
        GroupMessage(seq: seq, ts: t0.addingTimeInterval(offset), author: .human, name: "User", text: text, target: .everyone)
    }

    private let pickDB = AskQuestion(question: "Which database?", header: "Storage",
                                     options: [AskOption(label: "SQLite"), AskOption(label: "Postgres")])
    private let pickChecks = AskQuestion(question: "Which checks?", header: "CI", multiSelect: true,
                                         options: [AskOption(label: "lint"), AskOption(label: "unit"), AskOption(label: "e2e")])

    private func ask(_ offset: TimeInterval, id: Int, _ questions: [AskQuestion]? = nil) -> ChatEvent {
        ChatEvent(ts: iso(offset), kind: .ask, questions: questions ?? [pickDB], id: id)
    }

    private func prompt(_ offset: TimeInterval, id: Int, _ text: String = "My answers:\n- Which database? → SQLite") -> ChatEvent {
        ChatEvent(ts: iso(offset), kind: .prompt, text: text, id: id)
    }

    private func asks(_ items: [GroupTimelineItem]) -> [GroupAsk] {
        items.compactMap { if case .ask(let a) = $0 { return a } else { return nil } }
    }

    func testAMemberInTwoGroupsShowsItsQuestionInBoth() {
        let one = ChatGroup(name: "one", members: [api, web])
        let two = ChatGroup(name: "two", members: [qa, api])
        let ledgers = [api: [ask(10, id: 0)]]
        for group in [one, two] {
            let shown = asks(GroupAsks.timeline(group: group, messages: [message(1, at: 0)], ledgers: ledgers))
            XCTAssertEqual(shown.map(\.member), [api], group.name)
            XCTAssertEqual(shown.first?.questions, [pickDB])
            XCTAssertEqual(shown.first?.open, true)
        }
    }

    func testANonMembersQuestionIsNotShown() {
        let group = ChatGroup(name: "g", members: [api, web])
        let items = GroupAsks.timeline(group: group, messages: [message(1, at: 0)], ledgers: [qa: [ask(10, id: 0)]])
        XCTAssertTrue(asks(items).isEmpty)
        XCTAssertEqual(items.count, 1)
    }

    /// Answered from the member's own tab: the tab typed the answer, the hook logged the prompt,
    /// and the group card closes on that same prompt.
    func testAnAnswerInTheMembersSessionClosesTheGroupCard() {
        let group = ChatGroup(name: "g", members: [api, web])
        let open = asks(GroupAsks.timeline(group: group, messages: [message(1, at: 0)],
                                           ledgers: [api: [ask(10, id: 0)]]))
        XCTAssertEqual(open.map(\.open), [true])
        let answered = asks(GroupAsks.timeline(group: group, messages: [message(1, at: 0)],
                                               ledgers: [api: [ask(10, id: 0), prompt(20, id: 1)]]))
        XCTAssertEqual(answered.map(\.open), [false])
        XCTAssertEqual(answered.first?.id, open.first?.id, "the same item, now answered")
    }

    /// The tab and the group read one ledger with one rule, so they can never disagree.
    func testTheGroupCardIsOpenExactlyWhenTheTabsCardIs() {
        let ledgers: [[ChatEvent]] = [
            [ask(10, id: 0)],
            [ask(10, id: 0), ChatEvent(ts: iso(15), kind: .reply, text: "asked above", id: 1)],
            [ask(10, id: 0), prompt(20, id: 1)],
            [ask(10, id: 0), prompt(20, id: 1, "<task-notification><summary>done</summary></task-notification>")],
            [ask(10, id: 0), prompt(20, id: 1), ask(30, id: 2, [pickChecks])],
        ]
        for ledger in ledgers {
            let tab = ChatFolder.fold(ledger).items.compactMap { item -> Bool? in
                if case let .ask(_, _, _, open) = item { return open } else { return nil }
            }
            XCTAssertEqual(GroupAsks.asks(member: api, ledger: ledger).map(\.open), tab)
        }
        XCTAssertEqual(GroupAsks.asks(member: api, ledger: ledgers[4]).map(\.open), [false, true])
    }

    func testOrderedByTimeAmongTheMessagesWithTheMessageFirstOnATie() {
        let group = ChatGroup(name: "g", members: [api, web])
        let items = GroupAsks.timeline(group: group,
                                       messages: [message(1, at: 0), message(2, at: 10), message(3, at: 30)],
                                       ledgers: [api: [ask(10, id: 4), ask(20, id: 5)], web: [ask(5, id: 0)]])
        XCTAssertEqual(items.map(\.id), [
            "msg:1", "ask:\(web.uuidString):0", "msg:2", "ask:\(api.uuidString):4",
            "ask:\(api.uuidString):5", "msg:3",
        ])
    }

    func testMultiSelectQuestionsComeThroughWhole() {
        let group = ChatGroup(name: "g", members: [api, web])
        let shown = asks(GroupAsks.timeline(group: group, messages: [message(1, at: 0)],
                                            ledgers: [web: [ask(10, id: 0, [pickDB, pickChecks])]]))
        XCTAssertEqual(shown.first?.questions, [pickDB, pickChecks])
        XCTAssertEqual(shown.first?.questions.last?.multiSelect, true)
        XCTAssertEqual(shown.first?.questions.last?.options.map(\.label), ["lint", "unit", "e2e"])
    }

    func testAnAnsweredQuestionFromBeforeTheGroupIsLeftOutAnOpenOneIsNot() {
        let group = ChatGroup(name: "g", members: [api, web])
        let ledgers = [api: [ask(-100, id: 0), prompt(-90, id: 1), ask(-50, id: 2)]]
        let shown = asks(GroupAsks.timeline(group: group, messages: [message(1, at: 0)], ledgers: ledgers))
        XCTAssertEqual(shown.map(\.ledgerID), [2])
        XCTAssertEqual(asks(GroupAsks.timeline(group: group, messages: [], ledgers: ledgers)).map(\.ledgerID), [2],
                       "an empty group shows only what is still open")
    }

    func testABubbleNamesAnAddresseeTheTextDoesNotTag() {
        let names = [api: "api-fix", web: "web-ui"]
        func msg(_ text: String, _ target: GroupMessage.Target) -> GroupMessage {
            GroupMessage(seq: 1, ts: t0, author: .human, name: "User", text: text, target: target)
        }
        XCTAssertEqual(GroupTimeline.displayText(msg("My answers:", .members([api])), names: names), "@api-fix My answers:")
        XCTAssertEqual(GroupTimeline.displayText(msg("@web-ui ok?", .members([web])), names: names), "@web-ui ok?")
        XCTAssertEqual(GroupTimeline.displayText(msg("@web-ui ok?", .members([web, api])), names: names), "@api-fix @web-ui ok?")
        XCTAssertEqual(GroupTimeline.displayText(msg("hi", .everyone), names: names), "hi")
    }

    func testDayBreaksCoverQuestionsToo() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let group = ChatGroup(name: "g", members: [api, web])
        let items = GroupAsks.timeline(group: group, messages: [message(1, at: 0)],
                                       ledgers: [api: [ask(86_400 * 2, id: 0)]])
        XCTAssertEqual(GroupAsks.dayBreaks(items, calendar: calendar), Set(items.map(\.id)))
    }
}

@MainActor
final class GroupAnswerLogTests: XCTestCase {
    private var base: URL!
    private var store: GroupStore!
    private var service: GroupService!
    private var typed: [(UUID, String)] = []
    private let api = UUID(), web = UUID(), qa = UUID()

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("group-answer-\(UUID().uuidString)")
        store = GroupStore(base: base)
        service = GroupService(store: store)
        let names = [api: "api-fix", web: "web-ui", qa: "qa"]
        service.peers = { names.map { GroupPeer(id: $0.key, callsign: $0.value, status: .idle) } }
        service.deliver = { [self] id, text in typed.append((id, text)); return true }
        _ = try store.create(name: "Checkout fix", members: [api, web, qa]).get()
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: base) }

    func testAnAnswerIsLoggedToTheMemberAndWakesNobody() throws {
        let r = try service.logAnswer(group: "Checkout fix", to: api, text: "My answers:\n- Which? → SQLite").get()
        XCTAssertTrue(typed.isEmpty, "nobody is typed to by the log: the member already got the answer")
        XCTAssertTrue(r.woken.isEmpty)
        XCTAssertTrue(r.queued.isEmpty)
        XCTAssertFalse(service.hasPending(web))
        XCTAssertFalse(service.hasPending(qa))
        let message = try XCTUnwrap(r.message)
        XCTAssertEqual(GroupPrompt.line(message, names: [api: "api-fix"]), "User (to @api-fix): My answers:\n- Which? → SQLite")
    }

    func testTheAnsweredMemberIsNotHandedItAgainButTheOthersStillReadIt() throws {
        let r = try service.logAnswer(group: "Checkout fix", to: api, text: "SQLite").get()
        let group = try XCTUnwrap(store.group(ref: "Checkout fix"))
        XCTAssertEqual(store.cursor(api, group: group.id), r.message?.seq)
        XCTAssertTrue(store.unseen(by: api, in: group.id).isEmpty)
        XCTAssertEqual(store.unseen(by: web, in: group.id).map(\.text), ["SQLite"])
    }

    func testEarlierUnseenMessagesStillReachTheAnsweredMember() throws {
        _ = try service.post(group: "Checkout fix", from: .member(web), text: "fyi", wake: []).get()
        _ = try service.logAnswer(group: "Checkout fix", to: api, text: "SQLite").get()
        let group = try XCTUnwrap(store.group(ref: "Checkout fix"))
        XCTAssertEqual(store.unseen(by: api, in: group.id).map(\.text), ["fyi", "SQLite"])
    }

    func testWakeRestrictionLimitsWhoIsWoken() throws {
        let r = try service.post(group: "Checkout fix", from: .human, text: "status?", wake: [web]).get()
        XCTAssertEqual(r.woken, ["web-ui"])
        XCTAssertEqual(typed.map(\.0), [web])
    }

    func testNoRestrictionIsTheUsualRouting() throws {
        let r = try service.post(group: "Checkout fix", from: .human, text: "status?").get()
        XCTAssertEqual(Set(r.woken), ["api-fix", "web-ui", "qa"])
    }
}
