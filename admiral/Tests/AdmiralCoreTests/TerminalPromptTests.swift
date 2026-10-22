import XCTest
@testable import AdmiralCore

/// A long prompt typed in one burst lost everything but its tail: macOS hands claude the burst
/// in 1,022-byte reads, claude takes a read over ~800 bytes for a paste, and a shorter final
/// read wiped out the paste before it. Past one short burst, the long middle goes as a
/// bracketed paste instead, which claude reads whole however the PTY slices it.
final class TerminalPromptTests: XCTestCase {
    func testALineThatFitsOneBurstIsTypedWhole() {
        let middle = String(repeating: "a", count: TerminalPrompt.typedLimit - 4)
        XCTAssertEqual(TerminalPrompt.framing(middle, before: "@x: ", after: ""),
                       TerminalPrompt(typed: "@x: " + middle))
    }

    func testALongerLinePastesItsMiddleBetweenTheTypedEnds() {
        let middle = String(repeating: "a", count: TerminalPrompt.typedLimit - 3)
        XCTAssertEqual(TerminalPrompt.framing(middle, before: "@x: ", after: " end"),
                       TerminalPrompt(typedBefore: "@x: ", pasted: middle, typedAfter: " end"))
    }

    /// macOS slices the burst by bytes, so a line of two-byte characters is too long at half
    /// the character count.
    func testTheLimitCountsBytes() {
        let middle = String(repeating: "§", count: TerminalPrompt.typedLimit / 2)
        XCTAssertEqual(TerminalPrompt.framing(middle, before: "@x: ", after: "").pasted, middle)
    }

    func testAnInjectedTextAtTheLimitIsTypedWithNoTail() {
        let text = String(repeating: "a", count: TerminalPrompt.typedLimit)
        XCTAssertEqual(TerminalPrompt.injected(text), TerminalPrompt(typed: text))
    }

    func testAnInjectedTextPastTheLimitIsPastedWhole() {
        let text = String(repeating: "a", count: TerminalPrompt.typedLimit + 1)
        let prompt = TerminalPrompt.injected(text)
        XCTAssertEqual(prompt.pasted, text)
        XCTAssertEqual(prompt.typedBefore, "")
        XCTAssertLessThanOrEqual(prompt.typedAfter.utf8.count, TerminalPrompt.typedLimit)
    }

    func testBracketedWrapsOnlyThePastedPart() {
        let prompt = TerminalPrompt(typedBefore: "@x: ", pasted: "body", typedAfter: " [no reply needed]")
        XCTAssertEqual(prompt.bracketed, "@x: \u{1b}[200~body\u{1b}[201~ [no reply needed]")
    }

    /// An end marker inside the body would close the paste early and type the rest — the very
    /// burst this exists to avoid — so markers in the pasted part are dropped.
    func testBracketedDropsMarkersInsideThePaste() {
        let prompt = TerminalPrompt(typedBefore: "", pasted: "a\u{1b}[201~b\u{1b}[200~c", typedAfter: "")
        XCTAssertEqual(prompt.bracketed, "\u{1b}[200~abc\u{1b}[201~")
    }

    func testNothingPastedMeansNoMarkers() {
        XCTAssertEqual(TerminalPrompt(typed: "hi").bracketed, "hi")
    }
}
