import Foundation

/// Normalizes a station name, everywhere one is set. Mirrors the Python `names.sanitize`
/// so the two fleets cannot name the same thing differently.
///
/// A name is also an ADDRESS: `hail(to:)` takes it, and so does Claude Code's own
/// `SendMessage`, which separates a bare name from a trailing ` [ref]`. A name with a
/// space in it is genuinely ambiguous about where the name ends, so spaces collapse to
/// hyphens rather than being preserved.
///
/// The other two rules are not cosmetic. Claude Code strips `"`, `<` and `>` from a name
/// before it goes on the wire, and truncates at 64 characters with an ellipsis — so a name
/// kept verbatim past either limit renders one way in the tab and another in the peer's
/// prompt. Applying both here keeps the two sides identical.
public enum StationName {
    public static let maxLength = 64

    /// `name` as a valid station name. An empty result means "no name" — callers treat
    /// that as clearing the override, not as an error.
    public static func sanitize(_ name: String) -> String {
        // Whitespace collapses BEFORE invisibles are stripped: tab and newline are control
        // characters, so stripping first would silently join the words either side of them.
        let collapsed = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: "-")
        let visible = collapsed.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                && !CharacterSet.illegalCharacters.contains(scalar)
                && !"\"<>".unicodeScalars.contains(scalar)
        }
        // Hyphens that exist only because we replaced padding around a stripped
        // character are noise; a name never usefully starts or ends with one.
        let trimmed = String(String.UnicodeScalarView(visible))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(trimmed.prefix(maxLength))
    }
}
