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
    /// burst this exists to avoid — so markers in the pasted part lose their ESC and stay as
    /// inert text.
    func testBracketedDefusesMarkersInsideThePaste() {
        let prompt = TerminalPrompt(typedBefore: "", pasted: "a\u{1b}[201~b\u{1b}[200~c", typedAfter: "")
        XCTAssertEqual(prompt.bracketed, "\u{1b}[200~a[201~b[200~c\u{1b}[201~")
    }

    func testNothingPastedMeansNoMarkers() {
        XCTAssertEqual(TerminalPrompt(typed: "hi").bracketed, "hi")
    }

    /// Removing the end marker and then the start marker in one pass let the pieces around the
    /// start marker re-form an end marker: `ESC[20` + `ESC[200~` + `1~` became `ESC[201~`, which
    /// closed the paste early and typed the rest. No ESC survives in the pasted part.
    func testBracketedCannotReformAnEndMarkerFromThePiecesAroundAStartMarker() {
        let body = "\u{1b}[20" + "\u{1b}[200~" + "1~ then typed"
        let prompt = TerminalPrompt(typedBefore: "@x: ", pasted: body, typedAfter: " end")
        let wire = prompt.bracketed
        XCTAssertEqual(wire, "@x: \u{1b}[200~[20[200~1~ then typed\u{1b}[201~ end")
        XCTAssertEqual(wire.components(separatedBy: "\u{1b}[201~").count, 2,
                       "exactly one end marker, the real one")
    }

    // MARK: - Sanitizing

    func testSanitizedTurnsCRAndCRLFIntoLF() {
        XCTAssertEqual(TerminalPrompt.sanitized("a\rb\r\nc\nd\n\re"), "a\nb\nc\nd\n\ne")
    }

    func testSanitizedDropsEscapesControlsDELAndC1ButKeepsTabAndText() {
        let hostile = "ok\u{1b}[201~\u{03}\u{04}\u{7f}\u{9b}201~\u{85}\u{00}\tdone é 🚀"
        XCTAssertEqual(TerminalPrompt.sanitized(hostile), "ok[201~201~\tdone é 🚀")
    }

    func testPlainTextIsUnchangedBySanitizing() {
        let text = "@alice: fix the build (#12) — tabs\tand \"quotes\" stay"
        XCTAssertEqual(TerminalPrompt.sanitized(text), text)
    }

    /// The typed ends and the body all pass through it, so nothing hostile reaches the PTY on
    /// either the typed or the pasted path.
    func testFramingSanitizesEveryPart() {
        let prompt = TerminalPrompt.framing("hi\u{1b}[2J\u{03}", before: "@x\u{1b}: ", after: " end\u{7f}")
        XCTAssertEqual(prompt, TerminalPrompt(typed: "@x: hi[2J end"))
    }

    func testInjectedSanitizes() {
        XCTAssertEqual(TerminalPrompt.injected("run\u{1b}[A\u{15}it"), TerminalPrompt(typed: "run[Ait"))
    }

    /// A typed newline submits the prompt early, so a short text holding one is pasted.
    func testAShortBodyWithANewlineIsPastedNotTyped() {
        let prompt = TerminalPrompt.framing("ok\nsecond", before: "@x: ", after: " end")
        XCTAssertEqual(prompt, TerminalPrompt(typedBefore: "@x: ", pasted: "ok\nsecond", typedAfter: " end"))
    }

    func testAShortInjectWithACarriageReturnIsPastedWithItsTail() {
        let prompt = TerminalPrompt.injected("one\rtwo")
        XCTAssertEqual(prompt, TerminalPrompt(typedBefore: "", pasted: "one\ntwo",
                                              typedAfter: TerminalPrompt.injectedTail))
    }
}
