import XCTest
@testable import AdmiralCore

final class HookDispatcherStopTests: XCTestCase {
    private var base: URL!
    private let token = "stop-tok"

    override func setUp() {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("stop-hook-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: base) }

    private var schema: JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(#"{"type":"object"}"#.utf8))
    }
    private func dispatch() async -> String? {
        await HookDispatcher.handle(cliType: "claude", event: "Stop",
                                    payload: Data("{}".utf8), base: base, token: token)
    }

    func testNoTripwireIsSilentPass() async {
        let out = await dispatch()
        XCTAssertNil(out, "Stop stays a no-op when nothing is armed")
    }

    func testArmedTripwireBlocksWithInstructionAndCountsTheBlock() async {
        StructuredOutputStore.write(.init(schema: schema, delivery: .jsonText),
                                    base: base, token: token)
        let out = await dispatch()
        // The wire contract IS the JSON — assert the exact envelope (key order fixed).
        XCTAssertNotNil(out)
        XCTAssertTrue(out!.hasPrefix(#"{"decision":"block","reason":"#), out!)
        XCTAssertTrue(out!.contains("set_structured_output"))
        XCTAssertEqual(StructuredOutputStore.read(base: base, token: token)?.blocks, 1)
    }

    func testResolvedTripwireIsSilentPass() async {
        StructuredOutputStore.write(.init(schema: schema, delivery: .jsonText, status: .fulfilled),
                                    base: base, token: token)
        let out = await dispatch()
        XCTAssertNil(out)
    }

    func testBlocksExhaustionForceDisarms() async {
        StructuredOutputStore.write(.init(schema: schema, delivery: .jsonText, blocks: 3),
                                    base: base, token: token)
        let out = await dispatch()
        XCTAssertNil(out, "the 4th stop passes")
        XCTAssertEqual(StructuredOutputStore.read(base: base, token: token)?.status, .failed)
    }

    // MARK: - Several slots armed at once

    /// A Stop block carries one reason, so the highest-priority armed slot wins the turn —
    /// and ONLY its budget moves, or a session ignoring its goals nudge would burn the
    /// watchdog's blocks without ever being asked.
    func testHighestPrioritySlotWinsTheTurnAndOnlyItsBlocksMove() async {
        StructuredOutputStore.write(.init(schema: schema, delivery: .toolUse),
                                    base: base, token: token, type: .goals)
        StructuredOutputStore.write(.init(schema: schema, delivery: .jsonText),
                                    base: base, token: token, type: .api)
        let out = await dispatch()
        XCTAssertTrue(out!.contains(#"`type` set to \"api\""#), out!)
        XCTAssertEqual(StructuredOutputStore.read(base: base, token: token, type: .api)?.blocks, 1)
        XCTAssertEqual(StructuredOutputStore.read(base: base, token: token, type: .goals)?.blocks, 0)
    }

    /// Once the winner resolves, the next Stop blocks for whoever is still waiting.
    func testTheNextSlotTakesOverOnceTheWinnerResolves() async {
        StructuredOutputStore.write(.init(schema: schema, delivery: .toolUse),
                                    base: base, token: token, type: .goals)
        StructuredOutputStore.write(.init(schema: schema, delivery: .jsonText, status: .fulfilled),
                                    base: base, token: token, type: .api)
        let out = await dispatch()
        XCTAssertTrue(out!.contains(#"`type` set to \"goals\""#), out!)
        XCTAssertEqual(StructuredOutputStore.read(base: base, token: token, type: .goals)?.blocks, 1)
    }

    func testExhaustionFailsOnlyTheExhaustedSlot() async {
        StructuredOutputStore.write(.init(schema: schema, delivery: .toolUse, blocks: 3),
                                    base: base, token: token, type: .watchdog)
        StructuredOutputStore.write(.init(schema: schema, delivery: .toolUse),
                                    base: base, token: token, type: .goals)
        let out = await dispatch()
        XCTAssertNil(out, "the exhausted slot force-disarms instead of blocking again")
        XCTAssertEqual(StructuredOutputStore.read(base: base, token: token, type: .watchdog)?.status,
                       .failed)
        XCTAssertEqual(StructuredOutputStore.read(base: base, token: token, type: .goals)?.status,
                       .armed, "the goals nudge gets its turn on the next Stop")
    }

    func testMissingTokenIsSilentPass() async {
        StructuredOutputStore.write(.init(schema: schema, delivery: .jsonText),
                                    base: base, token: token)
        let out = await HookDispatcher.handle(cliType: "claude", event: "Stop",
                                              payload: Data("{}".utf8), base: base, token: nil)
        XCTAssertNil(out)
    }
}
