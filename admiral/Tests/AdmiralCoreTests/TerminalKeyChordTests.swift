import XCTest
@testable import AdmiralCore

final class TerminalKeyChordTests: XCTestCase {
    func testShiftArrows() throws {
        XCTAssertEqual(try TerminalKeyChord.encode("shift+left"), "\u{1b}[1;2D")
        XCTAssertEqual(try TerminalKeyChord.encode("shift+right"), "\u{1b}[1;2C")
        XCTAssertEqual(try TerminalKeyChord.encodeOne("left"), "\u{1b}[D")
    }

    func testShiftOAndCtrlC() throws {
        XCTAssertEqual(try TerminalKeyChord.encode("shift+o"), "O")
        XCTAssertEqual(try TerminalKeyChord.encode("ctrl+c"), "\u{03}")
    }

    func testSequence() throws {
        let s = try TerminalKeyChord.encode("shift+left,shift+right,shift+o")
        XCTAssertEqual(s, "\u{1b}[1;2D\u{1b}[1;2CO")
    }

    func testFunctionKeysAndRawHex() throws {
        XCTAssertEqual(try TerminalKeyChord.encode("f1"), "\u{1b}[11~")
        XCTAssertEqual(try TerminalKeyChord.encode("shift+f13"), "\u{1b}[25;2~")
        // raw: — backslash-e becomes ESC; semicolon must NOT split the CSI
        XCTAssertEqual(try TerminalKeyChord.encode(#"raw:\e[1;5A"#), "\u{1b}[1;5A")
        XCTAssertEqual(try TerminalKeyChord.encode("hex:1b5b41"), "\u{1b}[A")
    }

    func testLiteralPassThrough() throws {
        XCTAssertEqual(try TerminalKeyChord.encode("xyz"), "xyz")
    }
}
