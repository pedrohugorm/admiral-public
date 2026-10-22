import Foundation

/// What dropping files onto a terminal types: iTerm2's drop, byte for byte — each path
/// backslash-escaped for the shell, the paths joined by spaces, then one trailing space — so a
/// Finder drag lands in claude (or zsh) exactly as it does in iTerm2, e.g.
/// `/Users/me/Library/Mobile\ Documents/com\~apple\~CloudDocs/list.pdf `.
///
/// Ported from iTerm2's `-[PTYTextView pasteValuesOnPasteboard:cdToDirectory:]` and the
/// escaping its `filenamesOnPasteboardWithShellEscaping:` applies (sources/Categories/
/// NSStringITerm.m). Pure, so `swift test` pins it; the app reads the paths off the drag.
public enum TerminalDrop {
    /// iTerm2's `+[NSString shellEscapableCharacters]`, plus the CR/LF a drop escapes as well.
    /// iTerm2 escapes one character at a time with the backslash first, so no added backslash
    /// is escaped again — the same as prefixing each of these scalars once.
    static let shellEscaped = Set("\\ ()\"&'!$<>;|*?[]#`\t{}^+=@~\r\n".unicodeScalars)

    /// The text to type for the dropped `paths`, or nil when nothing was dropped.
    public static func pasteText(paths: [String]) -> String? {
        guard !paths.isEmpty else { return nil }
        return paths.map(escaped).joined(separator: " ") + " "
    }

    private static func escaped(_ path: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in path.unicodeScalars {
            if shellEscaped.contains(scalar) { out.append("\\") }
            out.append(scalar)
        }
        return String(out)
    }
}
