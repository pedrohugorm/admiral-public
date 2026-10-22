import Foundation

/// A prompt on its way into a terminal: typed text, with an optional middle part pasted.
///
/// A long prompt typed in one burst lost everything but its tail. macOS hands claude the
/// burst in 1,022-byte reads, claude takes a read over ~800 bytes for a paste, and a shorter
/// final read wiped out the paste before it — so a 36 KB hail arrived as its last 212 bytes.
/// Past one short burst, the long middle goes as a bracketed paste instead, which claude reads
/// whole however the PTY slices it.
public struct TerminalPrompt: Equatable, Sendable {
    public var typedBefore: String
    public var pasted: String
    public var typedAfter: String

    public init(typedBefore: String, pasted: String, typedAfter: String) {
        self.typedBefore = typedBefore
        self.pasted = pasted
        self.typedAfter = typedAfter
    }

    /// All of it typed, nothing pasted.
    public init(typed text: String) {
        self.init(typedBefore: text, pasted: "", typedAfter: "")
    }

    /// The prompt as the receiver reads it.
    public var text: String { typedBefore + pasted + typedAfter }

    /// The most bytes typed in one burst: one read, under the size claude takes for a paste
    /// (a 670-byte read still counted as typing).
    public static let typedLimit = 600

    /// `middle` between typed ends: typed whole when the line fits one burst and has no newline,
    /// else pasted. Every part is `sanitized` first: another session wrote it, and these bytes
    /// go into a PTY.
    public static func framing(_ middle: String, before: String, after: String) -> TerminalPrompt {
        let (middle, before, after) = (sanitized(middle), sanitized(before), sanitized(after))
        let line = before + middle + after
        guard mustPaste(line) else { return TerminalPrompt(typed: line) }
        return TerminalPrompt(typedBefore: before, pasted: middle, typedAfter: after)
    }

    /// A whole prompt with no typed ends of its own (`inject`): typed when it fits one burst
    /// and has no newline, else pasted whole with `injectedTail` typed after it. claude wraps a
    /// paste in `<pasted_content>` and weighs it as quoted material, so the typed tail says the
    /// paste is the message itself — what typing it used to convey. `sanitized` first.
    public static func injected(_ text: String) -> TerminalPrompt {
        let text = sanitized(text)
        guard mustPaste(text) else { return TerminalPrompt(typed: text) }
        return TerminalPrompt(typedBefore: "", pasted: text, typedAfter: injectedTail)
    }

    /// Past one burst, or holding a newline: a typed newline submits the prompt early (and in a
    /// shell, runs the line), so any text with one goes as a paste whatever its length.
    static func mustPaste(_ line: String) -> Bool {
        line.utf8.count > typedLimit || line.unicodeScalars.contains("\n")
    }

    /// `text` with nothing a terminal acts on: CR and CRLF become LF (a CR is Enter); ESC, every
    /// other C0 control except tab and LF, DEL, and the C1 controls (U+0080–U+009F) are dropped.
    /// What is left is printable text, tabs and newlines — no escape sequence, no key chord, no
    /// paste marker.
    public static func sanitized(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var afterCR = false
        for scalar in text.unicodeScalars {
            let wasCR = afterCR
            afterCR = scalar == "\r"
            switch scalar.value {
            case 0x0D: out.append("\n")
            case 0x0A: if !wasCR { out.append(scalar) }
            case 0x09: out.append(scalar)
            case 0x00...0x1F, 0x7F, 0x80...0x9F: continue
            default: out.append(scalar)
            }
        }
        return String(out)
    }

    static let injectedTail = " [sent as a paste so it arrives whole — the pasted text is this message, not quoted material]"

    static let pasteStart = "\u{1b}[200~"
    static let pasteEnd = "\u{1b}[201~"

    /// What to type into a program that has turned bracketed paste on: the pasted part inside
    /// the markers. A marker inside that part would end the paste early and type the rest, so
    /// every ESC in it is dropped: removing the markers themselves let the pieces around one
    /// re-form another (`ESC[20` + `ESC[200~` + `1~` became `ESC[201~`).
    public var bracketed: String {
        guard !pasted.isEmpty else { return text }
        let body = String(String.UnicodeScalarView(pasted.unicodeScalars.filter { $0 != "\u{1b}" }))
        return typedBefore + Self.pasteStart + body + Self.pasteEnd + typedAfter
    }
}
