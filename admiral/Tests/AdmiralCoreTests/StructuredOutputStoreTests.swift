import XCTest
@testable import AdmiralCore

final class StructuredOutputStoreTests: XCTestCase {
    private var base: URL!

    override func setUp() {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("so-store-\(UUID().uuidString)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: base) }

    private var schema: JSONValue {
        try! JSONDecoder().decode(JSONValue.self, from: Data(#"{"type":"object"}"#.utf8))
    }

    func testRoundTrip() {
        let state = StructuredOutputState(schema: schema, delivery: .toolUse, toolName: "report")
        XCTAssertTrue(StructuredOutputStore.write(state, base: base, token: "tok-1"))
        XCTAssertEqual(StructuredOutputStore.read(base: base, token: "tok-1"), state)
        // Written under the session dir, like settings.json / context.json.
        XCTAssertEqual(AdmiralPaths.structuredOutputFile(base: base, token: "tok-1").lastPathComponent,
                       "structured-output.json")
    }

    func testMissingAndClear() {
        XCTAssertNil(StructuredOutputStore.read(base: base, token: "none"))
        let state = StructuredOutputState(schema: schema, delivery: .jsonText)
        StructuredOutputStore.write(state, base: base, token: "tok-2")
        StructuredOutputStore.clear(base: base, token: "tok-2")
        XCTAssertNil(StructuredOutputStore.read(base: base, token: "tok-2"))
    }

    func testDeliveryRawValuesMatchWire() {
        XCTAssertEqual(StructuredOutputState.Delivery.jsonText.rawValue, "json_text")
        XCTAssertEqual(StructuredOutputState.Delivery.toolUse.rawValue, "tool_use")
    }

    // MARK: - Typed slots

    func testSlotsAreIndependent() {
        let api = StructuredOutputState(schema: schema, delivery: .jsonText)
        let watchdog = StructuredOutputState(schema: schema, delivery: .toolUse, blocks: 2)
        StructuredOutputStore.write(api, base: base, token: "t", type: .api)
        StructuredOutputStore.write(watchdog, base: base, token: "t", type: .watchdog)

        XCTAssertEqual(StructuredOutputStore.read(base: base, token: "t", type: .api), api)
        XCTAssertEqual(StructuredOutputStore.read(base: base, token: "t", type: .watchdog), watchdog)
        XCTAssertNil(StructuredOutputStore.read(base: base, token: "t", type: .goals))
    }

    func testClearingOneSlotLeavesTheOthers() {
        StructuredOutputStore.write(.init(schema: schema, delivery: .jsonText),
                                    base: base, token: "t", type: .api)
        StructuredOutputStore.write(.init(schema: schema, delivery: .toolUse),
                                    base: base, token: "t", type: .goals)
        StructuredOutputStore.clear(base: base, token: "t", type: .goals)

        XCTAssertNil(StructuredOutputStore.read(base: base, token: "t", type: .goals))
        XCTAssertNotNil(StructuredOutputStore.read(base: base, token: "t", type: .api))
    }

    /// "No file" has to keep meaning "this session owes nothing" — the Stop hook reads the
    /// file's absence as a fast pass.
    func testFileDisappearsWithTheLastSlot() {
        let url = AdmiralPaths.structuredOutputFile(base: base, token: "t")
        StructuredOutputStore.write(.init(schema: schema, delivery: .jsonText),
                                    base: base, token: "t", type: .watchdog)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        StructuredOutputStore.clear(base: base, token: "t", type: .watchdog)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testArmedIsReportedInPriorityOrder() {
        StructuredOutputStore.write(.init(schema: schema, delivery: .toolUse),
                                    base: base, token: "t", type: .goals)
        StructuredOutputStore.write(.init(schema: schema, delivery: .jsonText, status: .fulfilled),
                                    base: base, token: "t", type: .watchdog)
        StructuredOutputStore.write(.init(schema: schema, delivery: .jsonText),
                                    base: base, token: "t", type: .api)

        // Fulfilled slots aren't armed; the rest come back highest-priority first.
        XCTAssertEqual(StructuredOutputStore.readAll(base: base, token: "t").armed, [.api, .goals])
    }

    /// A session armed before slots existed still has a bare state on disk; it was always
    /// the endpoint's arm, and it must not read as "nothing armed".
    func testLegacySingleSlotFileMigratesToApi() throws {
        let legacy = StructuredOutputState(schema: schema, delivery: .jsonText, blocks: 1)
        let url = AdmiralPaths.structuredOutputFile(base: base, token: "old")
        try JSONEncoder().encode(legacy).write(to: url)

        XCTAssertEqual(StructuredOutputStore.read(base: base, token: "old", type: .api), legacy)
        XCTAssertEqual(StructuredOutputStore.readAll(base: base, token: "old").armed, [.api])
    }
}
