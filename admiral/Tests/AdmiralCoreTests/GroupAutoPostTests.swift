import XCTest
@testable import AdmiralCore

final class GroupAutoPostDecideTests: XCTestCase {
    private let me = UUID(), other = UUID()
    private lazy var group = ChatGroup(name: "Checkout fix", members: [me, other])

    private func message(_ seq: Int, by author: GroupMessage.Author) -> GroupMessage {
        GroupMessage(seq: seq, ts: Date(), author: author, name: "x", text: "m\(seq)", target: .everyone)
    }

    private func decide(_ reply: String?, group: ChatGroup?? = nil,
                        messages: [GroupMessage] = []) -> GroupAutoPost.Decision {
        GroupAutoPost.decide(reply: reply, member: me, wakeSeq: 2, group: group ?? self.group, messages: messages)
    }

    func testNothingToPost() {
        XCTAssertEqual(decide(nil), .skip(.noReply))
        XCTAssertEqual(decide(""), .skip(.noReply))
        XCTAssertEqual(decide(" \n\t "), .skip(.noReply))
    }

    func testPassIsNeverPosted() {
        XCTAssertEqual(decide("[pass]"), .skip(.passed))
        XCTAssertEqual(decide("  [pass]\n"), .skip(.passed))
    }

    func testAMessageByTheMemberAfterTheWakeMeansItAlreadyAnswered() {
        XCTAssertEqual(decide("done", messages: [message(1, by: .member(me)), message(2, by: .human),
                                                 message(3, by: .member(me))]), .skip(.alreadyPosted))
    }

    func testOlderOwnMessagesAndOthersMessagesDoNotCount() {
        XCTAssertEqual(decide("done", messages: [message(1, by: .member(me)), message(3, by: .member(other)),
                                                 message(4, by: .human)]), .post("done"))
    }

    func testGroupDeletedOrMemberRemoved() {
        XCTAssertEqual(decide("done", group: .some(nil)), .skip(.groupGone))
        XCTAssertEqual(decide("done", group: ChatGroup(name: "g", members: [other, UUID()])), .skip(.notAMember))
    }

    func testNormalReplyIsTrimmedAndPosted() {
        XCTAssertEqual(decide("\n  the total is right, @web-ui  \n"), .post("the total is right, @web-ui"))
    }

    func testLongReplyIsCutWithAMarker() {
        let long = String(repeating: "a", count: GroupAutoPost.maxChars + 500)
        XCTAssertEqual(decide(long), .post(String(repeating: "a", count: GroupAutoPost.maxChars)
                                            + GroupAutoPost.truncationMarker))
        let exact = String(repeating: "b", count: GroupAutoPost.maxChars)
        XCTAssertEqual(decide(exact), .post(exact))
    }
}

final class GroupAutoPostLedgerTests: XCTestCase {
    private let since = ISO8601DateFormatter().date(from: "2026-10-22T10:00:05Z")!.addingTimeInterval(0.6)

    private func prompt(_ ts: String, _ source: String?) -> ChatEvent {
        ChatEvent(ts: "2026-10-22T10:00:\(ts)Z", kind: .prompt, text: "p", source: source)
    }
    private func reply(_ ts: String, _ text: String) -> ChatEvent {
        ChatEvent(ts: "2026-10-22T10:00:\(ts)Z", kind: .reply, text: text)
    }

    func testTheLastReplyAfterTheGroupPromptInTheSameWholeSecond() {
        let ledger = [reply("05", "previous turn"), prompt("05", "group"), reply("09", "narration"),
                      reply("12", "final")]
        XCTAssertEqual(GroupAutoPost.finalReply(ledger: ledger, since: since), "final")
    }

    func testAnOlderGroupPromptIsNotThisTurn() {
        XCTAssertNil(GroupAutoPost.finalReply(ledger: [prompt("01", "group"), reply("02", "old")], since: since))
    }

    func testAnyOtherPromptAfterTheWakeCancels() {
        for source in [nil, "watchdog"] as [String?] {
            let ledger = [prompt("05", "group"), prompt("07", source), reply("12", "for the user")]
            XCTAssertNil(GroupAutoPost.finalReply(ledger: ledger, since: since), "\(source ?? "user")")
        }
    }

    func testAnUntaggedPromptCarryingTheGroupHeaderIsTheWake() {
        let wrapped = ChatEvent(ts: "2026-10-22T10:00:06Z", kind: .prompt,
                                text: "<peer from=\"Admiral\">[group \"g\" · a, b]\nUser: hi</peer>")
        XCTAssertEqual(GroupAutoPost.finalReply(ledger: [reply("05", "previous"), wrapped, reply("09", "hi back")],
                                                since: since), "hi back")
    }

    func testWithNoWakePromptInTheLedgerTheTurnStartsAtTheNextSecond() {
        XCTAssertEqual(GroupAutoPost.finalReply(ledger: [reply("05", "previous"), reply("09", "answer")],
                                                since: since), "answer")
        XCTAssertNil(GroupAutoPost.finalReply(ledger: [reply("05", "previous"), prompt("07", nil), reply("09", "x")],
                                              since: since))
    }

    func testNoReplyYet() {
        XCTAssertNil(GroupAutoPost.finalReply(ledger: [prompt("06", "group")], since: since))
    }
}

@MainActor
final class GroupAutoPostServiceTests: XCTestCase {
    private var base: URL!
    private var store: GroupStore!
    private var service: GroupService!
    private var typed: [(UUID, String)] = []
    private var status: [UUID: SessionStatus] = [:]
    private var ledger: [UUID: [ChatEvent]] = [:]
    private var enabled = true
    private var clock = ISO8601DateFormatter().date(from: "2026-10-22T10:00:00Z")!
    private var group: ChatGroup!
    private let api = UUID(), web = UUID(), qa = UUID()

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("group-autopost-\(UUID().uuidString)")
        store = GroupStore(base: base)
        service = GroupService(store: store)
        let names = [api: "api-fix", web: "web-ui", qa: "qa"]
        status = [api: .idle, web: .idle, qa: .idle]
        service.peers = { [self] in
            names.map { GroupPeer(id: $0.key, callsign: $0.value, status: status[$0.key] ?? .unknown) }
        }
        // A delivered wake lands in the member's ledger as a group-sourced prompt.
        service.deliver = { [self] id, text in
            typed.append((id, text))
            ledger[id, default: []].append(event(.prompt, text, source: GroupAutoPost.promptSource))
            return true
        }
        service.enabled = { [self] in enabled }
        service.now = { [self] in clock }
        service.finalReply = { [self] id, since in GroupAutoPost.finalReply(ledger: ledger[id] ?? [], since: since) }
        group = try store.create(name: "Checkout fix", members: [api, web, qa]).get()
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: base) }

    private func event(_ kind: ChatEvent.Kind, _ text: String, source: String? = nil) -> ChatEvent {
        clock += 1
        return ChatEvent(ts: ISO8601DateFormatter().string(from: clock), kind: kind, text: text, source: source)
    }

    /// `member` works through a turn and ends it with `reply`.
    private func finishTurn(_ member: UUID, reply: String) {
        status[member] = .busy
        service.postFinishedTurns()
        ledger[member, default: []].append(event(.reply, reply))
        status[member] = .idle
        service.postFinishedTurns()
    }

    private var log: [GroupMessage] { store.messages(group.id) }

    func testAWokenMemberThatAnswersInItsTurnIsPostedOnceAndWakesTheOthers() throws {
        _ = try service.post(group: "Checkout fix", from: .human, text: "@api-fix is it fixed?").get()
        XCTAssertEqual(typed.map(\.0), [api])
        typed = []

        finishTurn(api, reply: "Yes, merged. @web-ui please recheck")
        XCTAssertEqual(log.map(\.text), ["@api-fix is it fixed?", "Yes, merged. @web-ui please recheck"])
        XCTAssertEqual(log.last?.author, .member(api))
        XCTAssertEqual(typed.map(\.0), [web], "the tag in the posted reply wakes like any member message")
        XCTAssertEqual(store.group(group.id)?.spent, 1, "one budget spent")

        service.postFinishedTurns()
        status[api] = .busy; service.postFinishedTurns()
        status[api] = .idle; service.postFinishedTurns()
        XCTAssertEqual(log.count, 2, "the wake was settled; later ticks and turns post nothing")
    }

    func testIdleBeforeBusyPostsNothing() throws {
        _ = try service.post(group: "Checkout fix", from: .human, text: "@api-fix ping").get()
        ledger[api, default: []].append(event(.reply, "stale"))
        service.postFinishedTurns()
        service.postFinishedTurns()
        XCTAssertEqual(log.count, 1)
        XCTAssertNotNil(service.wakes[api], "still waiting for the turn")
    }

    func testAGroupSayDuringTheTurnIsNotPostedAgain() throws {
        _ = try service.post(group: "Checkout fix", from: .human, text: "@api-fix ping").get()
        status[api] = .busy
        service.postFinishedTurns()
        _ = try service.post(group: "Checkout fix", from: .member(api), text: "pong").get()
        ledger[api, default: []].append(event(.reply, "I posted pong to the group."))
        status[api] = .idle
        service.postFinishedTurns()
        XCTAssertEqual(log.map(\.text), ["@api-fix ping", "pong"])
        XCTAssertNil(service.wakes[api])
    }

    func testPassIsNotPosted() throws {
        _ = try service.post(group: "Checkout fix", from: .human, text: "@api-fix ping").get()
        finishTurn(api, reply: "[pass]")
        XCTAssertEqual(log.count, 1)
    }

    func testAPromptTheUserTypesIntoTheTabCancels() throws {
        _ = try service.post(group: "Checkout fix", from: .human, text: "@api-fix ping").get()
        status[api] = .busy
        service.postFinishedTurns()
        ledger[api, default: []].append(event(.prompt, "actually, stop and run the tests", source: nil))
        ledger[api, default: []].append(event(.reply, "tests pass"))
        status[api] = .idle
        service.postFinishedTurns()
        XCTAssertEqual(log.count, 1)
        XCTAssertNil(service.wakes[api])
    }

    func testAPausedGroupStillLogsTheReplyButWakesNobody() throws {
        _ = try service.post(group: "Checkout fix", from: .human, text: "@api-fix ping").get()
        for _ in 0..<ChatGroup.defaultBudget { store.spendBudget(group.id) }
        typed = []
        finishTurn(api, reply: "done @web-ui")
        XCTAssertEqual(log.last?.text, "done @web-ui")
        XCTAssertTrue(typed.isEmpty)
    }

    func testFlagOffRecordsNoWake() throws {
        // A queued wake flushed while the flag is off (post itself refuses).
        status[api] = .busy
        _ = try service.post(group: "Checkout fix", from: .human, text: "@api-fix ping").get()
        enabled = false
        status[api] = .idle
        service.flushPending()
        XCTAssertEqual(typed.map(\.0), [api])
        XCTAssertTrue(service.wakes.isEmpty)
        enabled = true
        finishTurn(api, reply: "pong")
        XCTAssertEqual(log.count, 1)
    }

    func testAFlushedWakeIsTrackedToo() throws {
        status[api] = .busy
        _ = try service.post(group: "Checkout fix", from: .human, text: "@api-fix ping").get()
        status[api] = .idle
        service.flushPending()
        finishTurn(api, reply: "pong")
        XCTAssertEqual(log.map(\.text), ["@api-fix ping", "pong"])
    }
}
