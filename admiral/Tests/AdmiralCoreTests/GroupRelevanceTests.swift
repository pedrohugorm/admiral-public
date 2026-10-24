import XCTest
@testable import AdmiralCore

final class GroupRelevanceSelectTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID()

    func testEveryoneAtOrAboveTheThresholdIsChosen() {
        let chosen = GroupRelevance.select(candidates: [a, b, c], scores: [a: 0.7, b: 0.69, c: 0.95],
                                           threshold: 0.7, fromHuman: false)
        XCTAssertEqual(chosen, [a, c])
    }

    func testNobodyAboveTheThresholdChoosesTheHighest() {
        let chosen = GroupRelevance.select(candidates: [a, b, c], scores: [a: 0.2, b: 0.5, c: 0.4],
                                           threshold: 0.7, fromHuman: false)
        XCTAssertEqual(chosen, [b])
    }

    func testATieBelowTheThresholdChoosesOne() {
        let chosen = GroupRelevance.select(candidates: [a, b], scores: [a: 0.3, b: 0.3],
                                           threshold: 0.7, fromHuman: true)
        XCTAssertEqual(chosen, [a])
    }

    func testNoScoresReachesEveryoneForTheUserAndNobodyForAnAgent() {
        XCTAssertEqual(GroupRelevance.select(candidates: [a, b], scores: [:], threshold: 0.7, fromHuman: true), [a, b])
        XCTAssertEqual(GroupRelevance.select(candidates: [a, b], scores: [:], threshold: 0.7, fromHuman: false), [])
    }

    func testAMemberTheScorerFailedOnIsLeftOutWhenOthersScored() {
        let chosen = GroupRelevance.select(candidates: [a, b], scores: [b: 0.1], threshold: 0.7, fromHuman: false)
        XCTAssertEqual(chosen, [b])
    }

    func testParseScore() {
        XCTAssertEqual(GroupRelevance.parseScore(#"Sure. {"score": 0.82, "why": "x"}"#), 0.82)
        XCTAssertEqual(GroupRelevance.parseScore("0.4"), 0.4)
        XCTAssertEqual(GroupRelevance.parseScore(#"{"score": 7}"#), 1)
        XCTAssertNil(GroupRelevance.parseScore("no idea"))
    }
}

@MainActor
final class GroupRelevanceServiceTests: XCTestCase {
    private var base: URL!
    private var store: GroupStore!
    private var service: GroupService!
    private var typed: [UUID] = []
    private final class ScoreTable: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [String: Double] = [:]
        func get() -> [String: Double] { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ new: [String: Double]) { lock.lock(); value = new; lock.unlock() }
    }
    private let scoreTable = ScoreTable()
    private var scores: [String: Double] {
        get { scoreTable.get() }
        set { scoreTable.set(newValue) }
    }
    private var api = UUID(), web = UUID(), qa = UUID()

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("group-relevance-\(UUID().uuidString)")
        store = GroupStore(base: base)
        service = GroupService(store: store)
        let names = [api: "api-fix", web: "web-ui", qa: "qa"]
        service.peers = { names.map { GroupPeer(id: $0.key, callsign: $0.value, status: .idle) } }
        service.deliver = { [self] id, _ in typed.append(id); return true }
        let table = scoreTable
        service.scoreRelevance = { prompt in
            for (callsign, score) in table.get() where prompt.contains("deciding for @\(callsign)") { return score }
            return nil
        }
        _ = try store.create(name: "Checkout fix", members: [api, web, qa]).get()
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: base) }

    private func post(_ text: String, from: GroupSender, to: [String] = []) async throws -> GroupPostResult {
        let result = try service.post(group: "Checkout fix", from: from, text: text, to: to).get()
        await service.relevanceTask?.value
        return result
    }

    func testUntaggedAgentMessageReachesOnlyTheMembersItIsFor() async throws {
        scores = ["web-ui": 0.9, "qa": 0.2]
        let result = try await post("the api contract changed", from: .member(api))
        XCTAssertEqual(Set(result.scoring), ["web-ui", "qa"])
        XCTAssertEqual(typed, [web])
    }

    func testNobodyOverTheThresholdWakesTheHighest() async throws {
        scores = ["web-ui": 0.3, "qa": 0.5]
        _ = try await post("ok", from: .member(api))
        XCTAssertEqual(typed, [qa])
    }

    func testUserMessageIsGatedToo() async throws {
        scores = ["api-fix": 0.9, "web-ui": 0.8, "qa": 0.1]
        _ = try await post("how is the contract", from: .human)
        XCTAssertEqual(Set(typed), [api, web])
    }

    func testScorerFailureWakesEveryoneForTheUserAndNobodyForAnAgent() async throws {
        scores = [:]
        _ = try await post("hello", from: .human)
        XCTAssertEqual(Set(typed), [api, web, qa])
        typed = []
        _ = try await post("hello back", from: .member(api))
        XCTAssertTrue(typed.isEmpty)
    }

    func testTaggedMessageSkipsTheScorer() async throws {
        scores = ["web-ui": 0.0, "qa": 0.0]
        let result = try await post("@web-ui can you look", from: .member(api))
        XCTAssertTrue(result.scoring.isEmpty)
        XCTAssertEqual(typed, [web])
    }

    func testAtAllSkipsTheScorer() async throws {
        let result = try await post("@all heads up", from: .member(api))
        XCTAssertTrue(result.scoring.isEmpty)
        XCTAssertEqual(Set(typed), [web, qa])
    }

    func testSwitchedOffEveryoneIsWokenAsBefore() async throws {
        service.relevanceEnabled = { false }
        _ = try await post("hello", from: .member(api))
        XCTAssertEqual(Set(typed), [web, qa])
    }
}
