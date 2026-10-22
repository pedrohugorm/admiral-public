import XCTest
@testable import AdmiralCore

/// `JSONValue` was read-only (transcript parsing). The engine graph's state carries a
/// `HookEvent`, whose `tool_input` is a `JSONValue`, and `GraphState: Codable` — so the
/// type must now round-trip, even though the production graph runs without a checkpointer.
final class JSONValueCodableTests: XCTestCase {
    private func roundTrip(_ value: JSONValue) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    func testScalarsRoundTrip() throws {
        XCTAssertEqual(try roundTrip(.string("hi")), .string("hi"))
        XCTAssertEqual(try roundTrip(.number(42)), .number(42))
        XCTAssertEqual(try roundTrip(.bool(true)), .bool(true))
        XCTAssertEqual(try roundTrip(.null), .null)
    }

    func testNestedContainersRoundTrip() throws {
        let value = JSONValue.object([
            "command": .string("ls -la"),
            "flags": .array([.string("-l"), .number(2), .bool(false), .null]),
            "nested": .object(["deep": .string("yes")]),
        ])

        XCTAssertEqual(try roundTrip(value), value)
    }

    /// The realistic payload: a Bash tool_input.
    func testAToolInputObjectRoundTrips() throws {
        let value = JSONValue.object(["command": .string("git branch feature/X")])

        XCTAssertEqual(try roundTrip(value), value)
        XCTAssertEqual(try roundTrip(value)["command"]?.stringValue, "git branch feature/X")
    }

    /// `HookEvent` must be `Codable` to sit in graph state. Note this is the *synthesized*
    /// coding (property names), distinct from `HookEvent.decode`, which reads Claude Code's
    /// wire keys. The two are deliberately separate.
}
