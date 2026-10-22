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

    /// `middle` between typed ends: typed whole when the line fits one burst, else pasted.
    public static func framing(_ middle: String, before: String, after: String) -> TerminalPrompt {
        let line = before + middle + after
        guard line.utf8.count > typedLimit else { return TerminalPrompt(typed: line) }
        return TerminalPrompt(typedBefore: before, pasted: middle, typedAfter: after)
    }

    /// A whole prompt with no typed ends of its own (`inject`): typed when it fits one burst,
    /// else pasted whole with `injectedTail` typed after it. claude wraps a paste in
    /// `<pasted_content>` and weighs it as quoted material, so the typed tail says the paste
    /// is the message itself — what typing it used to convey.
    public static func injected(_ text: String) -> TerminalPrompt {
        guard text.utf8.count > typedLimit else { return TerminalPrompt(typed: text) }
        return TerminalPrompt(typedBefore: "", pasted: text, typedAfter: injectedTail)
    }

    static let injectedTail = " [sent as a paste so it arrives whole — the pasted text is this message, not quoted material]"

    static let pasteStart = "\u{1b}[200~"
    static let pasteEnd = "\u{1b}[201~"

    /// What to type into a program that has turned bracketed paste on: the pasted part inside
    /// the markers. A marker inside that part would end the paste early and type the rest, so
    /// it is dropped.
    public var bracketed: String {
        guard !pasted.isEmpty else { return text }
        let body = pasted.replacingOccurrences(of: Self.pasteEnd, with: "")
            .replacingOccurrences(of: Self.pasteStart, with: "")
        return typedBefore + Self.pasteStart + body + Self.pasteEnd + typedAfter
    }
}
